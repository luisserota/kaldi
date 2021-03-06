#!/bin/bash

# run_tdnn_lstm_1c.sh is as run_tdnn_lstm_1a.sh, but about 1.5 times larger
# chunk lengths than 1a.
# There doesn't seem to be any advantage in the longer chunk lengths.

# this is a TDNN+LSTM system; the configuration is similar to
# local/chain/tuning/run_tdnn_lstm_1e.sh, but a non-chain nnet3 system, and
# with 1.5 times larger hidden dimensions.

# local/nnet3/compare_wer.sh --looped exp/nnet3_cleaned/tdnn_lstm1a_sp exp/nnet3_cleaned/tdnn_lstm1b_sp exp/nnet3_cleaned/tdnn_lstm1c_sp
# System                tdnn_lstm1a_sp tdnn_lstm1b_sp tdnn_lstm1c_sp
# WER on dev(orig)           11.0      11.0      11.0
#         [looped:]          11.0      11.1      10.9
# WER on dev(rescored)       10.3      10.3      10.4
#         [looped:]          10.3      10.5      10.3
# WER on test(orig)          10.8      10.6      10.8
#         [looped:]          10.7      10.7      10.7
# WER on test(rescored)      10.1       9.9      10.1
#         [looped:]          10.0      10.0      10.1
# Final train prob        -0.6881   -0.6897   -0.5998
# Final valid prob        -0.7796   -0.7989   -0.8542
# Final train acc          0.7954    0.7946    0.7988
# Final valid acc          0.7611    0.7582    0.7521



# by default, with cleanup:
# local/nnet3/run_tdnn_lstm.sh

# without cleanup:
# local/nnet3/run_tdnn_lstm.sh  --train-set train --gmm tri3 --nnet3-affix "" &


set -e -o pipefail -u

# First the options that are passed through to run_ivector_common.sh
# (some of which are also used in this script directly).
stage=0
nj=30
decode_nj=30
min_seg_len=1.55
train_set=train_cleaned
gmm=tri3_cleaned  # this is the source gmm-dir for the data-type of interest; it
                  # should have alignments for the specified training data.
num_threads_ubm=32
nnet3_affix=_cleaned  # cleanup affix for exp dirs, e.g. _cleaned

# Options which are not passed through to run_ivector_common.sh
affix=1c
common_egs_dir=
reporting_email=

# LSTM options
train_stage=-10
label_delay=5

# training chunk-options
chunk_width=60,50,40,30
chunk_left_context=40
chunk_right_context=0
# decode chunk-size options (for non-looped decoding)
extra_left_context=50
extra_right_context=0

# training options
srand=0
remove_egs=true

#decode options
extra_left_context=
extra_right_context=
frames_per_chunk=

. ./cmd.sh
. ./path.sh
. ./utils/parse_options.sh

if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

local/nnet3/run_ivector_common.sh --stage $stage \
                                  --nj $nj \
                                  --min-seg-len $min_seg_len \
                                  --train-set $train_set \
                                  --gmm $gmm \
                                  --num-threads-ubm $num_threads_ubm \
                                  --nnet3-affix "$nnet3_affix"



gmm_dir=exp/${gmm}
graph_dir=$gmm_dir/graph
ali_dir=exp/${gmm}_ali_${train_set}_sp_comb
dir=exp/nnet3${nnet3_affix}/tdnn_lstm${affix}
dir=${dir}_sp
train_data_dir=data/${train_set}_sp_hires_comb
train_ivector_dir=exp/nnet3${nnet3_affix}/ivectors_${train_set}_sp_hires_comb


for f in $train_data_dir/feats.scp $train_ivector_dir/ivector_online.scp \
     $graph_dir/HCLG.fst $ali_dir/ali.1.gz $gmm_dir/final.mdl; do
  [ ! -f $f ] && echo "$0: expected file $f to exist" && exit 1
done


if [ $stage -le 12 ]; then
  mkdir -p $dir
  echo "$0: creating neural net configs using the xconfig parser";

  num_targets=$(tree-info $gmm_dir/tree |grep num-pdfs|awk '{print $2}')

  mkdir -p $dir/configs
  cat <<EOF > $dir/configs/network.xconfig
  input dim=100 name=ivector
  input dim=40 name=input

  # please note that it is important to have input layer with the name=input
  # as the layer immediately preceding the fixed-affine-layer to enable
  # the use of short notation for the descriptor
  fixed-affine-layer name=lda input=Append(-2,-1,0,1,2,ReplaceIndex(ivector, t, 0)) affine-transform-file=$dir/configs/lda.mat

  # the first splicing is moved before the lda layer, so no splicing here
  relu-renorm-layer name=tdnn1 dim=768
  relu-renorm-layer name=tdnn2 dim=768 input=Append(-1,0,1)
  fast-lstmp-layer name=lstm1 cell-dim=768 recurrent-projection-dim=192 non-recurrent-projection-dim=192 decay-time=20 delay=-3
  relu-renorm-layer name=tdnn3 dim=768 input=Append(-3,0,3)
  relu-renorm-layer name=tdnn4 dim=768 input=Append(-3,0,3)
  fast-lstmp-layer name=lstm2 cell-dim=768 recurrent-projection-dim=192 non-recurrent-projection-dim=192 decay-time=20 delay=-3
  relu-renorm-layer name=tdnn5 dim=768 input=Append(-3,0,3)
  relu-renorm-layer name=tdnn6 dim=768 input=Append(-3,0,3)
  fast-lstmp-layer name=lstm3 cell-dim=768 recurrent-projection-dim=192 non-recurrent-projection-dim=192 decay-time=20 delay=-3

  output-layer name=output input=lstm3 output-delay=$label_delay dim=$num_targets max-change=1.5

EOF
  steps/nnet3/xconfig_to_configs.py --xconfig-file $dir/configs/network.xconfig --config-dir $dir/configs/
fi


if [ $stage -le 13 ]; then
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs/storage ]; then
    utils/create_split_dir.pl \
     /export/b0{3,4,5,6}/$USER/kaldi-data/egs/tedlium-$(date +'%m_%d_%H_%M')/s5_r2/$dir/egs/storage $dir/egs/storage
  fi

  steps/nnet3/train_rnn.py --stage=$train_stage \
    --cmd="$decode_cmd" \
    --feat.online-ivector-dir=$train_ivector_dir \
    --feat.cmvn-opts="--norm-means=false --norm-vars=false" \
    --trainer.srand=$srand \
    --trainer.max-param-change=2.0 \
    --trainer.num-epochs=6 \
    --trainer.deriv-truncate-margin=10 \
    --trainer.samples-per-iter=10000 \
    --trainer.optimization.num-jobs-initial=3 \
    --trainer.optimization.num-jobs-final=15 \
    --trainer.optimization.initial-effective-lrate=0.0003 \
    --trainer.optimization.final-effective-lrate=0.00003 \
    --trainer.optimization.shrink-value 0.99 \
    --trainer.rnn.num-chunk-per-minibatch=128,64 \
    --trainer.optimization.momentum=0.5 \
    --egs.chunk-width=$chunk_width \
    --egs.chunk-left-context=$chunk_left_context \
    --egs.chunk-right-context=$chunk_right_context \
    --egs.chunk-left-context-initial=0 \
    --egs.chunk-right-context-final=0 \
    --egs.dir="$common_egs_dir" \
    --cleanup.remove-egs=$remove_egs \
    --use-gpu=true \
    --feat-dir=$train_data_dir \
    --ali-dir=$ali_dir \
    --lang=data/lang \
    --reporting.email="$reporting_email" \
    --dir=$dir  || exit 1;
fi

if [ $stage -le 14 ]; then
  [ -z $extra_left_context ] && extra_left_context=$chunk_left_context;
  [ -z $extra_right_context ] && extra_right_context=$chunk_right_context;
  [ -z $frames_per_chunk ] && frames_per_chunk=$chunk_width;
  rm $dir/.error 2>/dev/null || true
  for dset in dev test; do
   (
    steps/nnet3/decode.sh --nj $decode_nj --cmd "$decode_cmd"  --num-threads 4 \
        --extra-left-context $extra_left_context \
        --extra-right-context $extra_right_context \
        --extra-left-context-initial 0 --extra-right-context-final 0 \
        --online-ivector-dir exp/nnet3${nnet3_affix}/ivectors_${dset}_hires \
      ${graph_dir} data/${dset}_hires ${dir}/decode_${dset} || exit 1
    steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang data/lang_rescore \
       data/${dset}_hires ${dir}/decode_${dset} ${dir}/decode_${dset}_rescore || exit 1
    ) || touch $dir/.error &
  done
  wait
  [ -f $dir/.error ] && echo "$0: there was a problem while decoding" && exit 1
fi


if [ $stage -le 15 ]; then
  # 'looped' decoding.
  # note: you should NOT do this decoding step for setups that have bidirectional
  # recurrence, like BLSTMs-- it doesn't make sense and will give bad results.
  # we didn't write a -parallel version of this program yet,
  # so it will take a bit longer as the --num-threads option is not supported.
  # we just hardcode the --frames-per-chunk option as it doesn't have to
  # match any value used in training, and it won't affect the results (unlike
  # regular decoding).
  rm $dir/.error 2>/dev/null || true
  for dset in dev test; do
      (
      steps/nnet3/decode_looped.sh --nj $decode_nj --cmd "$decode_cmd" \
          --frames-per-chunk 30 \
          --online-ivector-dir exp/nnet3${nnet3_affix}/ivectors_${dset}_hires \
         $graph_dir data/${dset}_hires $dir/decode_looped_${dset} || exit 1;
      steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" data/lang data/lang_rescore \
        data/${dset}_hires ${dir}/decode_looped_${dset} ${dir}/decode_looped_${dset}_rescore || exit 1
    ) || touch $dir/.error &
  done
  wait
  if [ -f $dir/.error ]; then
    echo "$0: something went wrong in decoding"
    exit 1
  fi
fi



exit 0;
