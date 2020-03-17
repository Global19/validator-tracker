#!/usr/bin/env bash


cluster=$1
if [[ -z $cluster ]]; then
  cluster=mainnet-beta
fi

solana_version=beta

case $cluster in
mainnet-beta)
  rpc_url=http://api.mainnet-beta.solana.com
  #source_stake_account=BMN8mAJ3Wxoi3RAKWx6NPJyk7WkkRwYi8awriUYcYMV9
  #authorized_staker=~/mainnet-beta-authorized-staker.json
  ;;
devnet)
  rpc_url=http://devnet.solana.com:8899
  ;;
slp)
  rpc_url=http://34.82.79.31
  source_stake_account=BMN8mAJ3Wxoi3RAKWx6NPJyk7WkkRwYi8awriUYcYMV9
  authorized_staker=~/slp-authorized-staker.json
  #source_stake_account=Gih5wD2kgwuHvecJTmD1Udu8TZNQDamY37SzuWugmBep
  #source_stake_account=Bkd4QoSvjkpK8SbQ5kieycCK7978qS14BpinQ5jmiogp
  #source_stake_account=3KnbTtzw3s6GTMoXWsVaSeGS6Sfeg2eLSeE3mXHo7UWG
  ;;
tds)
  rpc_url=http://tds.solana.com
  authorized_staker=~/tds-authorized-staker.json
  ;;
*)
  echo "Error: unsupported cluster: $cluster"
  exit 1
  ;;
esac

set -e
cd "$(dirname "$0")"

. configure-metrics.sh

if [[ -n $CI ]]; then
  curl -sSf https://raw.githubusercontent.com/solana-labs/solana/v1.0.0/install/solana-install-init.sh \
    | sh -s - $solana_version \
        --no-modify-path \
        --data-dir ./solana \
        --config config.yml

  export PATH="$PWD/solana/releases/$solana_version/solana-release/bin/:$PATH"
fi

current_slot=$(solana --url $rpc_url get-slot)
validators=$(solana --url $rpc_url show-validators)

max_slot_distance=216000 # ~24 hours worth of slots at 2.5 slots per second


current_vote_pubkeys=()
delinquent_vote_pubkeys=()

# Current validators:
for id_vote_slot in $(echo "$validators" | sed -ne "s/^  \\([^ ]*\\)   *\\([^ ]*\\) *[0-9]*%  *\\([0-9]*\\) .*/\\1=\\2=\\3/p"); do
  declare id=${id_vote_slot%%=*}
  declare vote_slot=${id_vote_slot#*=}
  declare vote=${vote_slot%%=*}
  declare slot=${vote_slot##*=}

  current_vote_pubkeys+=("$vote")
  $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=true slot=${slot}"
done

# Delinquent validators:
for id_vote_slot in $(echo "$validators" | sed -ne "s/^\\(⚠️ \\|! \\)\\([^ ]*\\) *\\([^ ]*\\) *[0-9]*%  *\\([0-9]*\\) .*/\\2=\\3=\\4/p"); do
  declare id=${id_vote_slot%%=*}
  declare vote_slot=${id_vote_slot#*=}
  declare vote=${vote_slot%%=*}
  declare slot=${vote_slot##*=}

  if ((slot < current_slot - max_slot_distance)); then
    delinquent_vote_pubkeys+=("$vote")
    $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=false slot=${slot}"
  else
    current_vote_pubkeys+=("$vote")
    $metricsWriteDatapoint "validators,cluster=$cluster,id=$id,ok=true slot=${slot}"
  fi
done



#
# Run through all the current/delinquent vote accounts and delegate/deactivate
# stake.  This is done quite naively
#
[[ -n $authorized_staker ]] || exit
(
  set -x
  solana --url $rpc_url --keypair $authorized_staker balance
)
current=1
for vote_pubkey in "${current_vote_pubkeys[@]}" - "${delinquent_vote_pubkeys[@]}"; do
  if [[ $vote_pubkey = - ]]; then
    current=0
    continue
  fi

  seed="${vote_pubkey:0:32}"

  stake_address="$(solana --url $rpc_url --keypair $authorized_staker create-address-with-seed "$seed" STAKE)"
  echo "Vote account: $vote_pubkey | Stake address: $stake_address"

  if ! solana --url $rpc_url stake-account "$stake_address"; then
    (
      set -x

      if [[ -n $source_stake_account ]]; then
        solana --url $rpc_url --keypair $authorized_staker split-stake $source_stake_account $authorized_staker --seed "$seed" 5000
      else
        solana --url $rpc_url --keypair $authorized_staker create-stake-account $authorized_staker --seed "$seed" 5000
      fi
    )
  fi

  if ((current)); then
    (
      set -x
      solana --url $rpc_url --keypair $authorized_staker delegate-stake "$stake_address" "$vote_pubkey"
    ) || true
  else
    (
      set -x
      solana --url $rpc_url --keypair $authorized_staker deactivate-stake "$stake_address"
    ) || true
  fi
done

exit 0
