#!/bin/bash
set -e

gh_branch="main"
gh_user="hypha-bot"

# Store current date and time
start_date=$(date +"%Y%m%d_%H-%M-%S")

# Stop cosmovisor
echo "Stopping cosmovisor"
systemctl stop cosmovisor

# Use quicksync as statesync is not reliable
echo "Installing utils needed to quicksync and git"
apt-get install wget liblz4-tool aria2 bc git-lfs -y

# Configure Git
echo "Configuring git"
cd ~
if [ ! -d ~/.ssh ]
then
    mkdir -m 700 ~/.ssh
fi

ssh-keyscan github.com >> ~/.ssh/known_hosts
git config --global credential.helper store
git config --global user.name "$gh_user"
git config --global user.email $gh_user@users.noreply.github.com
# Do not pull files in LFS by default
git config --global filter.lfs.smudge "git-lfs smudge --skip -- %f"
git config --global filter.lfs.process "git-lfs filter-process --skip"

echo "Creating script for gaia user"
echo "#!/bin/bash
echo \"cd ~/.gaia\"
cd ~/.gaia
echo \"Set URL\"
URL=\$(curl https://quicksync.io/cosmos.json|jq -r '.[] |select(.file==\"cosmoshub-4-pruned\")|.url')
echo \"URL set to: \$URL\"
echo \"Starting download\"
aria2c -x5 \$URL
echo \"Download checksum script\"
wget https://raw.githubusercontent.com/chainlayer/quicksync-playbooks/master/roles/quicksync/files/checksum.sh
chmod +x checksum.sh
echo \"Download \$URL.checksum\"
wget \$URL.checksum
echo \"Get sha512sum\"
curl -s https://lcd-cosmos.cosmostation.io/txs/\$(curl -s \$URL.hash)|jq -r '.tx.value.memo'|sha512sum -c
echo \"Checking hash of download\"
./checksum.sh \$(basename \$URL) check
if [ \$? -ne 0 ]
then
	echo "Checksum FAILED falling back to statesync"
	rm \$(basename \$URL)
else
	echo \"Execting \$(basename \$URL)\"
	lz4 -d \$(basename \$URL) | tar xf -
	echo \"Removing \$(basename \$URL)\"
	rm \$(basename \$URL)
fi
if [ ! -d cosmovisor/upgrades ]
then
    echo \"Creating cosmovisor/upgrades/v7-Theta/bin directory\"
    mkdir -p cosmovisor/upgrades/v7-Theta/bin
    cp cosmovisor/genesis/bin/gaiad cosmovisor/upgrades/v7-Theta/bin/gaiad
fi
" > ~gaia/quicksync.sh
chmod +x ~gaia/quicksync.sh
echo "Running ~gaia/quicksync.sh as gaia user"
su gaia -c '~gaia/quicksync.sh'

echo "Starting cosmovisor"
systemctl start cosmovisor

# Wait for gaia service to respond
echo "Waiting for gaia to respond"
attempt_counter=0
max_attempts=100
until $(curl --output /dev/null --silent --head --fail http://127.0.0.1:26657)
do
    if [ ${attempt_counter} -gt ${max_attempts} ]
    then
        echo ""
        echo "Tried connecting to gaiad for $attempt_counter times. Exiting."
        exit 1
    fi

    printf '.'
    attempt_counter=$(($attempt_counter+1))
    sleep 1
done

# Wait until gaiad is done catching up
catching_up="true"
while [ $catching_up == "true" ]
do
	catching_up=$(curl -s 127.0.0.1:26657/status | jq -r .result.sync_info.catching_up)
	echo "catching up"
	sleep 5
done
echo "Done catching up"

# Get current block height
current_block=$(curl -s 127.0.0.1:26657/block | jq -r .result.block.header.height)
echo "Current block: $current_block"

# Get block timestamp
current_block_time=$(curl -s 127.0.0.1:26657/block\?height=$current_block | jq -r .result.block.header.time)
echo "Current block timestamp: $current_block_time"

# Stop cosmovisor before exporting
echo "stop cosmovisor"
systemctl stop cosmovisor

# Clone cosmos-genesis-tinkerer
echo "Cloning cosmos-genesis-tinkerer"
cd ~
git clone git@github.com:hyphacoop/cosmos-genesis-tinkerer.git
cd cosmos-genesis-tinkerer/
git checkout $gh_branch

# Get version number using gaiad version
echo "Get running gaiad version"
gaiad_version=$(su gaia -c "~gaia/.gaia/cosmovisor/current/bin/gaiad version")
echo "Installed gaiad version is $gaiad_version"

# Export genesis
if [ ! -d mainnet-genesis-export ]
then
    mkdir mainnet-genesis-export
fi
echo "Export genesis"
su gaia -c "~gaia/.gaia/cosmovisor/current/bin/gaiad export --height $current_block" 2> "mainnet-genesis-export/mainnet-genesis_$current_block_time\_$gaiad_version\_$current_block.json"

echo "Tinkering exported genesis"
pip3 install -r requirements.txt
ln -s "$PWD/mainnet-genesis-export/mainnet-genesis_$current_block_time\_$gaiad_version\_$current_block.json" "tests/mainnet_genesis.json"
python3 ./example_mainnet_genesis.py
rm tests/mainnet_genesis.json
if [ ! -d mainnet-genesis-tinkered ]
then
    mkdir mainnet-genesis-tinkered
fi
mv tinkered_genesis.json "mainnet-genesis-tinkered/tinkered-genesis_$current_block_time\_$gaiad_version\_$current_block.json"


# Compress files
echo "Compressing mainnet-genesis-export/mainnet-genesis_$current_block_time\_$gaiad_version\_$current_block.json"
gzip "mainnet-genesis-export/mainnet-genesis_$current_block_time\_$gaiad_version\_$current_block.json"
echo "Compressing mainnet-genesis-tinkered/tinkered-genesis_$current_block_time\_$gaiad_version\_$current_block.json"
gzip "mainnet-genesis-tinkered/tinkered-genesis_$current_block_time\_$gaiad_version\_$current_block.json"

# Push to github
echo "push to github"
git lfs install
git lfs track "*.gz"
git add -A
git commit -m "Adding mainnet and tinkered genesis at height $current_block"
git push origin $gh_branch

# Print current date and time
echo -n "Finished at: "
date

# Push log to cosmos-configurations-private repo
echo "Push log to cosmos-configurations-private repo"
cd ~
git clone git@github.com:hyphacoop/cosmos-configurations-private.git
cd cosmos-configurations-private
if [ ! -d logs/mainnet-export ]
then
    mkdir -p logs/mainnet-export
fi
# wait for log to be written
sleep 120
cp /root/export_genesis.log logs/mainnet-export/mainnet-genesis_$start_date\_$gaiad_version\_$current_block.log
git add -A
git commit -m "Adding export log file"
git push origin main

# DESTROY the droplet from itself
curl -X DELETE -H "Authorization: Bearer {{ digitalocean_api_key }}" "https://api.digitalocean.com/v2/droplets/{{ droplet_id }}"
