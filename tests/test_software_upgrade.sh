#!/bin/bash 
# Test a gaia software upgrade via governance proposal.
# It assumes gaia is running on the local host.

gaia_host=$1
gaia_port=$2
upgrade_version=$3

echo "Attempting upgrade to $upgrade_version."

# Add gaiad to PATH
echo "Adding gaiad to PATH..."
export PATH="$PATH:~/.gaia/cosmovisor/current/bin"
echo "PATH=$PATH"

# Get the current gaia version from the API
gaiad_version=$(curl -s http://$gaia_host:$gaia_port/abci_info | jq -r .result.response.version)

# Submit upgrade proposal
gaiad_version_major=${gaiad_version:1:1}
echo "Current major version: $gaiad_version_major"

upgrade_version_major=${upgrade_version:1:1}
echo "Upgrade major version: $upgrade_version_major"
major_difference=$[ $upgrade_version_major-$gaiad_version_major ]

if [ $major_difference -eq 1 ]; then
    if [ $upgrade_version_major -eq 7 ]; then
        upgrade_name="v7-Theta"
    elif [ $upgrade_version_major -eq 8 ]; then
        upgrade_name="v8-Rho"
    fi
fi

if [ -n "$upgrade_name" ]; then
    echo "Upgrading to $upgrade_name."

    # Set time to wait for proposal to pass
    #voting_period=$(curl -s http://localhost:26657/genesis\? | jq -r '.result.genesis.app_state.gov.voting_params.voting_period')
    voting_period=$(cat ~/.gaia/config/genesis.json | jq -r '.app_state.gov.voting_params.voting_period')
    voting_period_seconds=${voting_period::-1}
    echo "Using ($voting_period_seconds)s voting period to calculate the upgrade height."
    
    # Calculate upgrade height
    let voting_blocks_delta=$voting_period_seconds/5+3
    height=$(curl -s http://$gaia_host:$gaia_port/block | jq -r .result.block.header.height)
    upgrade_height=$(($height+$voting_blocks_delta))
    echo "Upgrade block height set to $upgrade_height."

    # Get validator address
    echo "Querying gaiad for the validator address..."
    validator_address=$(jq -r '.address' ~/.gaia/validator.json)
    echo "The validator has address $validator_address."

    # Auto download: Set the binary paths need for the proposal message
    download_path="https://github.com/cosmos/gaia/releases/download/$upgrade_version"
    upgrade_info="{\"binaries\":{\"linux/amd64\":\"$download_path/gaiad-$upgrade_version-linux-amd64\",\"linux/arm64\":\"$download_path/$upgrade_version/gaiad-$upgrade_version-linux-arm64\",\"darwin/amd64\":\"$download_path/gaiad-$upgrade_version-darwin-amd64\",\"windows/amd64\":\"$download_path/gaiad-$upgrade_version-windows-amd64.exe\"}}"
    proposal="gaiad tx gov submit-proposal software-upgrade $upgrade_name --from $validator_address --keyring-backend test --upgrade-height $upgrade_height --upgrade-info $upgrade_info --title gaia-upgrade --description 'test' --chain-id my-testnet --deposit 10stake --yes"

    # Submit the proposal
    echo "Submitting the upgrade proposal."
    echo $proposal
    $proposal

    # Wait for the proposal to go on chain
    sleep 6

    # Vote yes on the proposal
    echo "Submitting the \"yes\" vote."
    vote="gaiad tx gov vote 1 yes --from $validator_address --keyring-backend test --chain-id my-testnet --yes"
    echo $vote
    $vote

    # Wait for the voting period to be over
    echo "Waiting for the voting period to end..."
    sleep 8

    echo "Upgrade proposal status:"
    gaiad q gov proposal 1 --output json | jq '.status'

    # Wait until the right height is reached
    echo "Waiting for the upgrade to take place at block height $upgrade_height..."
    tests/test_block_production.sh $gaia_host $gaia_port $upgrade_height
    echo "The upgrade height was reached."

    # Test gaia response
    tests/test_gaia_response.sh $gaia_host $gaia_port

    # Get running version
    gaiad_upgraded_version=$(curl -s http://$gaia_host:$gaia_port/abci_info | jq -r .result.response.version)
    echo "Current gaiad version: $gaiad_upgraded_version"

    # Check upgraded version is the one we want
    if [[ "$gaiad_upgraded_version" != "$upgrade_version" ]]; then
        echo "Requested $upgrade_version, but detected $gaiad_upgraded_version."
        exit 4
    fi

    # Test block production
    tests/test_block_production.sh $gaia_host $gaia_port $[$upgrade_height+10]

else
    echo "No upgrade name specified, skipping upgrade."
fi

