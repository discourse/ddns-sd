FROM ruby:2.6-alpine

MAINTAINER Matt Palmer "matt.palmer@discourse.org"

COPY Gemfile Gemfile.lock /home/ddnssd/

RUN adduser -D ddnssd \
	&& docker_group="$(getent group 999 | cut -d : -f 1)" \
	&& if [ -z "$docker_group" ]; then addgroup -g 999 docker; docker_group=docker; fi \
	&& addgroup ddnssd "$docker_group" \
	&& apk update \
	&& apk add build-base \
	&& apk add postgresql-dev \
	&& cd /home/ddnssd \
	&& su -pc 'gem install bundler:2.1.2' ddnssd \
	&& su -pc 'bundle config set without development' ddnssd \
	&& su -pc 'bundle config set deployment true' ddnssd \
	&& su -pc 'bundle install' ddnssd \
	&& apk del build-base \
	&& rm -rf /tmp/* /var/cache/apk/*

ARG GIT_REVISION=invalid-build
ENV DDNSSD_GIT_REVISION=$GIT_REVISION DDNSSD_DISABLE_LOG_TIMESTAMPS=yes

COPY bin/* /usr/local/bin/
COPY lib/ /usr/local/lib/ruby/2.6.0/

EXPOSE 9218
LABEL org.discourse.service._prom-exp.port=9218 org.discourse.service._prom-exp.instance=ddns-sd

USER ddnssd
WORKDIR /home/ddnssd
ENTRYPOINT ["/usr/local/bin/bundle", "exec", "/usr/local/bin/ddns-sd"]
