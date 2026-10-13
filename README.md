# Sfera Labs apt repository

Packages for Sfera Labs products are published at [apt.sferalabs.cc](https://apt.sferalabs.cc).

## Install

Bootstrap the repository key and source configuration over HTTPS:

    curl -fLO https://apt.sferalabs.cc/bootstrap/sferalabs-archive-keyring_all.deb
    sudo apt install ./sferalabs-archive-keyring_all.deb
    sudo apt update
