# Build from the repository root: podman build -f deploy/Dockerfile .
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:2fa828c68761b1b8c23d7662dc134421b9d3b59fe1425fdbc80804e390cdb24d AS build
WORKDIR /src
COPY rubyc-web/rubyc-web.csproj rubyc-web/
RUN dotnet restore rubyc-web/rubyc-web.csproj
COPY rubyc-web/ rubyc-web/
RUN dotnet publish rubyc-web/rubyc-web.csproj -c Release --no-restore -o /out

FROM docker.io/nginxinc/nginx-unprivileged:stable-alpine@sha256:daa17b944bac2b578e962da4c61ad72a59233b3c63abea17113acaf4e6b9aea4
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /out/wwwroot/ /usr/share/nginx/html/
USER 101:101
EXPOSE 8080
# Skip image init scripts: config is complete and the container filesystem is read-only.
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
