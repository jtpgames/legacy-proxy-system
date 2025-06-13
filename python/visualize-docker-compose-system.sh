#!/bin/bash

docker run --platform linux/amd64 --rm -it \
  --name dcv \
  -v "$(pwd)":/input \
  pmsipilot/docker-compose-viz \
  render -m image --force --no-volumes -o docker-compose-legacy.png docker-compose-legacy.yml

docker run --platform linux/amd64 --rm -it \
  --name dcv \
  -v "$(pwd)":/input \
  pmsipilot/docker-compose-viz \
  render -m image --force --no-volumes -o docker-compose-ng.png docker-compose-ng.yml
