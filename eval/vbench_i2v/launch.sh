#!/bin/bash

set -x
set -e

CKPT=$1
NUM_FRAMES=$2
MODEL_NAME=$3

if [[ $CKPT == *"ema"* ]]; then
    parentdir=$(dirname $CKPT)
    CKPT_BASE=$(basename $parentdir)_ema
else
    CKPT_BASE=$(basename $CKPT)
fi
LOG_BASE=$(dirname $CKPT)/eval
echo "Logging to $LOG_BASE"

GPUS=(0 1 2 3 4 5 6 7)
TASK_ID_LIST=(5a 5b 5c 5d 5e 5f 5g 5h)

for i in "${!GPUS[@]}"; do
    CUDA_VISIBLE_DEVICES=${GPUS[i]} bash eval/sample.sh $CKPT $NUM_FRAMES $MODEL_NAME -${TASK_ID_LIST[i]} >${LOG_BASE}/${TASK_ID_LIST[i]}.log 2>&1 &
done
