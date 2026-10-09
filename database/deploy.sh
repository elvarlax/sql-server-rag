#!/bin/sh
# Deploy the SQL project to the db service, or check the database for schema drift.
#   publish (default): create or update the database to match the project
#   drift:             report differences between the database and the project; fails if there are any
set -e

DACPAC=bin/Release/RagDemo.dacpac
TARGET="Server=db;Database=RagDemo;User ID=sa;Password=$SQL_PASSWORD;TrustServerCertificate=True"

# The DiskANN index is created by ingest, outside the project, so it doesn't count as a difference
case "${1:-publish}" in
  publish)
    sqlpackage /Action:Publish /SourceFile:$DACPAC /TargetConnectionString:"$TARGET" \
      /Variables:AppPassword="$SQL_APP_PASSWORD" /p:DropIndexesNotInSource=False
    ;;
  drift)
    sqlpackage /Action:DeployReport /SourceFile:$DACPAC /TargetConnectionString:"$TARGET" \
      /Variables:AppPassword="$SQL_APP_PASSWORD" /p:DropIndexesNotInSource=False /OutputPath:/tmp/report.xml
    if grep -q "<Operation " /tmp/report.xml; then
      cat /tmp/report.xml
      echo "Schema drift: the database differs from the project"
      exit 1
    fi
    echo "No schema drift"
    ;;
  *)
    echo "Usage: deploy.sh [publish|drift]"
    exit 2
    ;;
esac
