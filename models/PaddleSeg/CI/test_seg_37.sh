#!/bin/bash
unset GREP_OPTIONS
mkdir run_env_py37;
ln -s $(which python3.7) run_env_py37/python;
ln -s $(which pip3.7) run_env_py37/pip;
export PATH=$(pwd)/run_env_py37:${PATH};

python -m pip install pip==20.2.4 --ignore-installed;
python -m pip uninstall paddlepaddle-gpu -y
if [[ ${branch} == 'develop' ]];then
echo "checkout develop !"
python -m pip install ${paddle_dev} --no-cache-dir
else
echo "checkout release !"
python -m pip install ${paddle_release} --no-cache-dir
fi

echo -e '*****************paddle_version*****'
python -c 'import paddle;print(paddle.version.commit)'
echo -e '*****************paddleseg_version****'
git rev-parse HEAD


git diff --numstat --diff-filter=AMR upstream/${branch} | grep -v legacy | grep .yml | grep -v quick_start | grep configs | grep -v _base_ | grep -v setr | grep -v portraitnet | grep -v EISeg | grep -v contrib |  grep -v Matting |  grep -v test_tipc | grep -v benchmark | grep -v smrt | grep -v pssl | awk '{print $NF}' | tee dynamic_config_list_temp
echo =================
cat dynamic_config_list_temp
echo =================
seg_model_sign=False
success_num=0
fail_num=0
case_num=0
if [ -d "log" ];then rm -rf log
fi
mkdir log
if [ -d "log_err" ];then rm -rf log_err
fi
mkdir log_err
if [ -d "output" ];then rm -rf output
fi
#install paddleseg
pip install -v -e .
#cpp infer compile
cd deploy/cpp
wget https://github.com/opencv/opencv/archive/3.4.7.tar.gz
tar -xf 3.4.7.tar.gz
mkdir -p opencv-3.4.7/build
cd opencv-3.4.7/build
install_path=/usr/local/opencv3
cmake .. -DCMAKE_INSTALL_PREFIX=${install_path} -DCMAKE_BUILD_TYPE=Release
make -j
make install
cd ..
cd ..
wget https://github.com/jbeder/yaml-cpp/archive/refs/tags/yaml-cpp-0.7.0.zip
unzip yaml-cpp-0.7.0.zip
mkdir -p yaml-cpp-yaml-cpp-0.7.0/build
cd yaml-cpp-yaml-cpp-0.7.0/build
cmake -DYAML_BUILD_SHARED_LIBS=ON ..
make -j
make install
cd ..
cd ..
wget ${paddle_inference}
tar xvf paddle_inference.tgz
WITH_MKL=ON
WITH_GPU=ON
USE_TENSORRT=OFF
DEMO_NAME=test_seg
work_path=$(dirname $(readlink -f $0))
LIB_DIR="${work_path}/paddle_inference"
mkdir -p build
cd build
rm -rf *
cmake .. \
  -DDEMO_NAME=${DEMO_NAME} \
  -DWITH_MKL=${WITH_MKL} \
  -DWITH_GPU=${WITH_GPU} \
  -DUSE_TENSORRT=${USE_TENSORRT} \
  -DWITH_STATIC_LIB=OFF \
  -DPADDLE_LIB=${LIB_DIR}
make -j
cd ..
cd ..
cd ..
# prepare dynamic data
mkdir data
if [ -d "data/cityscapes" ];then rm -rf data/cityscapes
fi
ln -s ${file_path}/data/cityscape_seg/cityscape data/cityscapes
if [ -d "data/VOCdevkit" ]; then rm -rf data/VOCdevkit
fi
ln -s ${file_path}/data/pascalvoc/VOCdevkit data/VOCdevkit
if [ -d "data/ADEChallengeData2016" ]; then rm -rf data/ADEChallengeData2016
fi
ln -s ${file_path}/data/ADEChallengeData2016 data/ADEChallengeData2016
if [ -d "data/camvid" ]; then rm -rf data/camvid
fi
ln -s ${file_path}/data/camvid data/camvid
if [ -d "seg_dynamic_pretrain" ];then rm -rf seg_dynamic_pretrain
fi
ln -s ${file_path}/data/seg_dynamic_pretrain seg_dynamic_pretrain

print_result(){
    if [ $? -ne 0 ];then
        echo -e "${model},${mode},FAIL"
        cd ${log_dir}/log_err
        if [ ! -d ${model} ];then
            mkdir ${model}
        fi
        cd ../${model_type_path}
        cat ${log_dir}/log/${model}/${model}_${mode}.log
        mv ${log_dir}/log/${model}/${model}_${mode}.log ${log_dir}/log_err/${model}/
        seg_model_sign=True
        fail_num=$(($fail_num+1))
        case_num=$(($case_num+1))
    else
        echo -e "${model},${mode},SUCCESS"
        success_num=$(($success_num+1))
        case_num=$(($case_num+1))
    fi
}

# run dynamic models
pip install -r requirements.txt --ignore-installed
log_dir=.
model_type_path=
dynamic_config_num=`cat dynamic_config_list_temp | wc -l`
if [ ${dynamic_config_num} -eq 0 ];then
find . | grep configs | grep .yml | grep -v _base_ | grep -v quick_start | grep -v EISeg | grep -v contrib | grep -v Matting | grep -v setr | grep -v test_tipc | grep -v benchmark | grep -v smrt | grep -v pssl | tee dynamic_config_all
shuf dynamic_config_all -n 2 -o dynamic_config_list_temp
fi
grep -F -v -f no_upload dynamic_config_list_temp | sort | uniq | tee dynamic_config_list
sed -i "s/trainaug/train/g" configs/_base_/pascal_voc12aug.yml
skip_export_model='gscnn_resnet50_os8_cityscapes_1024x512_80k espnetv1_cityscapes_1024x512_120k enet_cityscapes_1024x512_80k segnet_cityscapes_1024x512_80k'
# dynamic fun
TRAIN_MUlTI_DYNAMIC(){
    export CUDA_VISIBLE_DEVICES=$cudaid2
    mode=train_multi_dynamic
    if [[ ${model} =~ 'segformer' ]];then
        echo -e "${model} does not test multi_train！"
    else
        python -m paddle.distributed.launch tools/train.py \
           --config ${config} \
           --save_interval 100 \
           --iters 10 \
           --save_dir output/${model} >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
        print_result
    fi
}
TRAIN_SINGLE_DYNAMIC(){
    export CUDA_VISIBLE_DEVICES=$cudaid1
    mode=train_single_dynamic
    if [[ ${model} =~ 'segformer' ]];then
        echo -e "${model} does not test single_train！"
    else
        python tools/train.py \
           --config ${config} \
           --save_interval 100 \
           --iters 10 \
           --save_dir output/${model} >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
        print_result
    fi
}
EVAL_DYNAMIC(){
    export CUDA_VISIBLE_DEVICES=$cudaid2
    mode=eval_dynamic
    python -m paddle.distributed.launch tools/val.py \
       --config ${config} \
       --model_path seg_dynamic_pretrain/${model}/model.pdparams >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
    print_result
}
PREDICT_DYNAMIC(){
    mode=predict_dynamic
    python tools/predict.py \
       --config ${config} \
       --model_path seg_dynamic_pretrain/${model}/model.pdparams \
       --image_path demo/${predict_pic} \
       --save_dir output/${model}/result >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
    print_result
}
EXPORT_DYNAMIC(){
    mode=export_dynamic
    if [[ ${model} =~ 'rtformer' || ${model} =~ 'dmnet' ]];then
        export CUDA_VISIBLE_DEVICES=$cudaid1
        python tools/export.py \
           --config ${config} \
           --model_path seg_dynamic_pretrain/${model}/model.pdparams \
           --save_dir ./inference_model/${model} \
           --input_shape 1 3 1024 2048 >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
        print_result
    elif [[ -z `echo ${skip_export_model} | grep -w ${model}` ]];then
        export CUDA_VISIBLE_DEVICES=$cudaid1
        python tools/export.py \
           --config ${config} \
           --model_path seg_dynamic_pretrain/${model}/model.pdparams \
           --save_dir ./inference_model/${model} >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
        print_result
    else
        echo -e "${model} does not support export!"
    fi
}
PYTHON_INFER_DYNAMIC(){
    mode=python_infer_dynamic
    if [ ! -d ./inference_model/${model} ];then
        echo -e "${model} doesn't run export case,so can't run PYTHON_INFER case!"
    else
        export PYTHONPATH=`pwd`
        python deploy/python/infer.py \
           --config ./inference_model/${model}/deploy.yaml \
           --image_path ./demo/${predict_pic} \
           --save_dir ./python_infer_output/${model} >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
        print_result
    fi
}
CPP_INFER(){
    mode=cpp_infer
    if [ ! -d ./inference_model/${model} ];then
        echo -e "${model} doesn't run export case,so can't run CPP_INFER case!"
    else
        ./deploy/cpp/build/test_seg \
           --model_dir=inference_model/${model} \
           --img_path=demo/${predict_pic} \
           --save_dir=cpp_infer_output/${model} \
           --devices=GPU >${log_dir}/log/${model}/${model}_${mode}.log 2>&1
        print_result
    fi
}

for config in `cat dynamic_config_list`
do
tmp=${config##*/}
model=${tmp%.*}
echo "${model}"
cd log && mkdir ${model}
cd ..
predict_pic='leverkusen_000029_000019_leftImg8bit.png'
if [[ -n `echo ${model} | grep voc12` ]];then
    predict_pic='2007_000033.jpg'
fi
if [[ -n `echo ${model} | grep voc12` ]] && [[ ! -f seg_dynamic_pretrain/${model}/model.pdparams ]];then
    wget -P seg_dynamic_pretrain/${model}/ https://bj.bcebos.com/paddleseg/dygraph/pascal_voc12/${model}/model.pdparams
elif [[ -n `echo ${model} | grep cityscapes` ]] && [[ ! -f seg_dynamic_pretrain/${model}/model.pdparams ]];then
    wget -P seg_dynamic_pretrain/${model}/ https://paddleseg.bj.bcebos.com/dygraph/cityscapes/${model}/model.pdparams
elif [[ -n `echo ${model} | grep ade20k` ]] && [[ ! -f seg_dynamic_pretrain/${model}/model.pdparams ]];then
    wget -P seg_dynamic_pretrain/${model}/ https://paddleseg.bj.bcebos.com/dygraph/ade20k/${model}/model.pdparams
elif [[ -n `echo ${model} | grep camvid` ]] && [[ ! -f seg_dynamic_pretrain/${model}/model.pdparams ]];then
    wget -P seg_dynamic_pretrain/${model}/ https://paddleseg.bj.bcebos.com/dygraph/camvid/${model}/model.pdparams
fi
if [ ! -s seg_dynamic_pretrain/${model}/model.pdparams ];then
    echo "${model} doesn't upload bos !!!"
else
    TRAIN_MUlTI_DYNAMIC
    TRAIN_SINGLE_DYNAMIC
    EVAL_DYNAMIC
    PREDICT_DYNAMIC
    EXPORT_DYNAMIC
    PYTHON_INFER_DYNAMIC
    CPP_INFER
fi
done

echo "A total of $case_num seg model cases have been tested，$success_num cases SUCCESS, $fail_num cases FAILED!！"


echo ++++++++++++++++++++++++ Seg To Onnx Test is beginning!!! ++++++++++++++++++++++++

python -m pip install onnx==1.8.0 tqdm filelock
python -m pip install onnxruntime==1.10.0
python -m pip install protobuf
python -m pip install six
python -m pip install paddle2onnx

rm -rf main_test.sh && rm -rf models_txt
cp -r ${file_path}/scripts/Seg2ONNX/. .
bash main_test.sh -p python -b develop -g True -t seg
onnx_sign=$?

echo ++++++++++++++++++++++++ final results is here ++++++++++++++++++++++++
if [[ ${onnx_sign} -ne 0 || ${seg_model_sign} != False ]]; then
#echo seg_model_sign is ${seg_model_sign}
#echo onnx_sign is ${onnx_sign}
echo "Seg CI: A total of $case_num seg model cases have been tested, $fail_num cases FAILED, $success_num cases SUCCESS!！"
echo "Onnx CI: A total of 6 to onnx cases have been tested，${onnx_sign} cases FAILED!! "
echo FAILED!!! oh no...
exit 1
else
echo "Seg CI: A total of $case_num seg model cases have been tested, $fail_num cases FAILED, $success_num cases SUCCESS!！"
echo "Onnx CI: A total of 6 to onnx cases have been tested，${onnx_sign} cases FAILED!! "
echo SUCCESS!!! nice~
exit 0
fi
