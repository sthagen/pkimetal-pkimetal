# BUILD.
FROM docker.io/library/golang:1.23.1-alpine AS build

# Install build dependencies.
RUN apk add --no-cache --update \
	# Common.
	gcc git g++ make \
	# certlint.
	ruby ruby-dev \
	# ftfy and pkilint.
	pipx \
	# pkilint (for pyasn1-fasder).
	rustup \
	# x509lint.
	openssl-dev

# Clone all of the linter repositories (except x509lint).
WORKDIR /usr/local
RUN git clone https://github.com/certlint/certlint && \
	git clone https://github.com/CVE-2008-0166/dwklint && \
	git clone https://github.com/CVE-2008-0166/dwk_blocklists && \
	git clone https://github.com/digicert/pkilint && \
	git clone https://github.com/rspeer/python-ftfy && \
	git clone https://github.com/zmap/zlint

# Build certlint (most recent tag).
WORKDIR /usr/local/certlint
RUN git checkout $(git describe --tags $(git rev-list --tags --max-count=1))
WORKDIR /usr/local/certlint/ext
RUN ruby extconf.rb && \
	make

# Checkout dwklint (most recent tag).
WORKDIR /usr/local/dwklint
RUN git checkout $(git describe --tags $(git rev-list --tags --max-count=1))

# Build ftfy wheel (most recent tag).
WORKDIR /usr/local/python-ftfy
ENV PATH="/root/.local/bin:${PATH}"
RUN git checkout $(git describe --tags $(git rev-list --tags --max-count=1)) && \
	pipx install poetry && \
	pipx inject poetry poetry-plugin-bundle && \
	poetry bundle venv --python=/usr/bin/python3 --only=main /app/ftfy

# Install rust + cargo using rustup (for pyasn1-fasder).
ENV PATH="/root/.cargo/bin:${PATH}"
RUN rustup-init -y && . "$HOME/.cargo/env"
# Build pkilint wheel (most recent tag).
WORKDIR /usr/local/pkilint
COPY linter/pkilint/pyproject.toml .
RUN git checkout $(git describe --tags $(git rev-list --tags --max-count=1)) && \
	poetry bundle venv --python=/usr/bin/python3 --only=main /app/pkilint

# Clone and prepare x509lint (most recent commit, because there are no tags).
WORKDIR /app/linter/x509lint
RUN git clone https://github.com/kroeckx/x509lint && \
	cd x509lint && \
	cp asn1_time.c asn1_time.h checks.c checks.h messages.c messages.h ..

# Build pkimetal.
WORKDIR /app
COPY . .
RUN git fetch --unshallow | echo
ENV GOPATH=/app
RUN CGO_ENABLED=1 GOOS=linux go build -o pkimetal -ldflags " \
	-X github.com/pkimetal/pkimetal/config.BuildTimestamp=`date --utc +%Y-%m-%dT%H:%M:%SZ` \
	-X github.com/pkimetal/pkimetal/config.PkimetalVersion=`git describe --tags --always` \
	-X github.com/pkimetal/pkimetal/linter/certlint.GitDescribeTagsAlways=`cd /usr/local/certlint && git describe --tags --always` \
	-X github.com/pkimetal/pkimetal/linter/certlint.RubyDir=/usr/local/certlint \
	-X github.com/pkimetal/pkimetal/linter/dwklint.GitDescribeTagsAlways=`cd /usr/local/dwklint && git describe --tags --always` \
	-X github.com/pkimetal/pkimetal/linter/dwklint.BlocklistDir=/usr/local/dwk_blocklists \
	-X github.com/pkimetal/pkimetal/linter/ftfy.GitDescribeTagsAlways=`cd /usr/local/python-ftfy && git describe --tags --always` \
	-X github.com/pkimetal/pkimetal/linter/ftfy.PythonDir=`find /app/ftfy/lib/python*/site-packages -maxdepth 0` \
	-X github.com/pkimetal/pkimetal/linter/pkilint.GitDescribeTagsAlways=`cd /usr/local/pkilint && git describe --tags --always` \
	-X github.com/pkimetal/pkimetal/linter/pkilint.PythonDir=`find /app/pkilint/lib/python*/site-packages -maxdepth 0` \
	-X github.com/pkimetal/pkimetal/linter/x509lint.GitDescribeTagsAlways=`cd /app/linter/x509lint/x509lint && git describe --tags --always` \
	-X github.com/pkimetal/pkimetal/linter/zlint.GitDescribeTagsAlways=`cd /usr/local/zlint && git describe --tags --always`" /app/.


# RUNTIME.
FROM alpine:edge AS runtime

# Install runtime dependencies.
RUN apk add --no-cache --update \
	# certlint.
	ruby \
	# pkilint and ftfy.
	python3

# Install certlint.
COPY --from=build /usr/local/certlint /usr/local/certlint
RUN gem install public_suffix simpleidn

# Copy dwk_blocklists.
COPY --from=build /usr/local/dwk_blocklists /usr/local/dwk_blocklists

# Install ftfy.
COPY --from=build /app/ftfy /app/ftfy

# Install pkilint.
COPY --from=build /app/pkilint /app/pkilint

# pkimetal.
WORKDIR /app
RUN wget https://ccadb.my.salesforce-sites.com/ccadb/AllCertificateRecordsCSVFormatv2 && \
	wget -O finding_metadata.csv.smime https://raw.githubusercontent.com/digicert/pkilint/main/pkilint/cabf/smime/finding_metadata.csv && \
	wget -O finding_metadata.csv.serverauth https://raw.githubusercontent.com/digicert/pkilint/main/pkilint/cabf/serverauth/finding_metadata.csv && \
	wget -O finding_metadata.csv.etsi https://raw.githubusercontent.com/digicert/pkilint/main/pkilint/etsi/finding_metadata.csv
COPY --from=build /app/pkimetal /app/pkimetal
CMD ["/app/pkimetal"]
