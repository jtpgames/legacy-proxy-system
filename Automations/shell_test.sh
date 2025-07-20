#!/usr/bin/env bash

echo "SHELL env variable: $SHELL"
echo "Current shell executing this script: $(ps -p $$ -o comm=)"
echo "Bash version: $BASH_VERSION"
echo "Zsh version: $ZSH_VERSION"
