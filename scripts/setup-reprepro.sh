#!/bin/bash

REPO_DIR="gh-pages/debian"
CONF_DIR="repo-config"

# Clear old data
rm -rf "$REPO_DIR" "$CONF_DIR"

# Initialize config dir
mkdir -p "$REPO_DIR"
mkdir -p "$CONF_DIR"/conf

Codename="resolute"
Suite="$Codename"

# Generate core configs
cat > "$CONF_DIR"/conf/distributions <<EOF
Origin: apt-repo
Label: apt-repo
Description: Self APT Repository
Codename: $Codename
Suite: $Suite
Architectures: amd64
Components: main
SignWith: yes
EOF

# Import packages
for deb in downloaded_packages/*.deb; do
    # Import into repo
    reprepro -V -b "$CONF_DIR" -S misc includedeb "$Codename" "$deb"
done

# Generate meta
reprepro -b "$CONF_DIR" export "$Codename"

# Merge files to release
rsync -a "$CONF_DIR"/ "$REPO_DIR/"
