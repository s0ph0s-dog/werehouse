FROM alpine:latest as build
ARG GH_USER=s0ph0s-dog
ARG GH_PROGRAM=werehouse
ARG GH_VERSION=1.1.1
RUN apk add --update bash zip
RUN wget https://github.com/${GH_USER}/${GH_PROGRAM}/releases/download/v${GH_VERSION}/${GH_PROGRAM}-${GH_VERSION}.com -O werehouse.com
RUN chmod +x werehouse.com

RUN sh ./werehouse.com --assimilate

FROM scratch

WORKDIR /data
COPY --from=build ./werehouse.com /bin/werehouse.com

ENV TZ=UTC
EXPOSE 80
EXPOSE 443
CMD ["/bin/werehouse.com", "-D", "."]
