# Builds the SQL project into a .dacpac and publishes it to the db service (see docker-compose.yml).
# `docker compose run --rm schema drift` checks the database for schema drift instead.
FROM mcr.microsoft.com/dotnet/sdk:10.0

RUN dotnet tool install --global microsoft.sqlpackage --version 170.5.96
ENV PATH="$PATH:/root/.dotnet/tools"

WORKDIR /src
COPY . .
RUN dotnet build -c Release && chmod +x deploy.sh

ENTRYPOINT ["./deploy.sh"]
CMD ["publish"]
