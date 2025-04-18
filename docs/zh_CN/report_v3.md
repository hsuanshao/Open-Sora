# Open-Sora 1.2 报告

- [视频压缩网络](#视频压缩网络)
- [整流流和模型适应](#整流流和模型适应)
- [更多数据和更好的多阶段训练](#更多数据和更好的多阶段训练)
- [简单有效的模型调节](#简单有效的模型调节)
- [评估](#评估)

在 Open-Sora 1.2 版本中，我们在 >30M 数据上训练了 一个1.1B 的模型，支持 0s~16s、144p 到 720p、各种宽高比的视频生成。我们的配置如下所列。继 1.1 版本之后，Open-Sora 1.2 还可以进行图像到视频的生成和视频扩展。

|      | 图像 | 2秒  | 4秒  | 8秒  | 16秒 |
| ---- | ----- | --- | --- | --- | --- |
| 240p | ✅     | ✅   | ✅   | ✅   | ✅   |
| 360p | ✅     | ✅   | ✅   | ✅   | ✅   |
| 480p | ✅     | ✅   | ✅   | ✅   | 🆗   |
| 720p | ✅     | ✅   | ✅   | 🆗   | 🆗   |

这里✅表示在训练期间可以看到数据，🆗表示虽然没有经过训练，但模型可以在该配置下进行推理。🆗的推理需要多个80G内存的GPU和序列并行。

除了 Open-Sora 1.1 中引入的功能外，Open-Sora 1.2 还有以下重磅更新：

- 视频压缩网络
- 整流流训练
- 更多数据和更好的多阶段训练
- 简单有效的模型调节
- 更好的评估指标

上述改进的所有实现（包括训练和推理）均可在 Open-Sora 1.2 版本中使用。以下部分将介绍改进的细节。我们还改进了代码库和文档，使其更易于使用。

## 视频压缩网络

对于 Open-Sora 1.0 & 1.1，我们使用了 stable-ai 的 83M 2D VAE，它仅在空间维度上压缩，将视频压缩 8x8 倍。为了减少时间维度，我们每三帧提取一帧。然而，这种方法导致生成的视频流畅度较低，因为牺牲了生成的帧率（fps）。因此，在这个版本中，我们引入了像 OpenAI 的 Sora 一样的视频压缩网络。该网络在时域上将视频大小压缩至四分之一，因此，我们不必再额外抽帧，而可以使用原有帧率生成模型。

考虑到训练 3D VAE 的计算成本很高，我们希望重新利用在 2D VAE 中学到的知识。我们注意到，经过 2D VAE 压缩后，时间维度上相邻的特征仍然高度相关。因此，我们提出了一个简单的视频压缩网络，首先将视频在空间维度上压缩 8x8 倍，然后将视频在时间维度上压缩 4 倍。网络如下所示：

![video_compression_network](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/report_3d_vae.png)

我们用[SDXL 的 VAE](https://huggingface.co/stabilityai/sdxl-vae)初始化 2D VAE ，它比我们以前使用的更好。对于 3D VAE，我们采用[Magvit-v2](https://magvit.cs.cmu.edu/v2/)中的 VAE 结构，它包含 300M 个参数。加上 83M 的 2D VAE，视频压缩网络的总参数为 384M。我们设定batch size 为 1， 对 3D VAE 进行了 1.2M 步的训练。训练数据是来自 pixels 和 pixabay 的视频，训练视频大小主要是 17 帧，256x256 分辨率。3D VAE 中使用causal convolotions使图像重建更加准确。

我们的训练包括三个阶段：

1. 对于前 380k 步，我们冻结 2D VAE并在 8 个 GPU 上进行训练。训练目标包括重建 2D VAE 的压缩特征（图中粉红色），并添加损失以使 3D VAE 的特征与 2D VAE 的特征相似（粉红色和绿色，称为identity loss）。我们发现后者的损失可以快速使整个 VAE 在图像上取得良好的性能，并在下一阶段更快地收敛。
2. 对于接下来的 260k 步，我们消除identity loss并仅学习 3D VAE。
3. 对于最后 540k 步，由于我们发现仅重建 2D VAE 的特征无法带来进一步的改进，因此我们移除了loss并训练整个 VAE 来重建原始视频。此阶段在 24 个 GPU 上进行训练。

对于训练的前半部分，我们采用 20% 的图像和 80% 的视频。按照[Magvit-v2](https://magvit.cs.cmu.edu/v2/)，我们使用 17 帧训练视频，同时对图像的前 16 帧进行零填充。然而，我们发现这种设置会导致长度不同于 17 帧的视频变得模糊。因此，在第 3 阶段，我们使用不超过34帧长度的任意帧长度视频进行混合视频长度训练,以使我们的 VAE 对不同视频长度更具鲁棒性（也就是说，如果我们希望训练含有n帧的视频，我们就把原视频中`34-n`帧用0进行填充）。我们的 [训练](/scripts/train_vae.py)和[推理](/scripts/inference_vae.py)代码可在 Open-Sora 1.2 版本中找到。

当使用 VAE 进行扩散模型时，我们的堆叠 VAE 所需的内存较少，因为我们的 VAE 的输入已经经过压缩。我们还将输入视频拆分为几个 17 帧剪辑，以提高推理效率。我们的 VAE 与[Open-Sora-Plan](https://github.com/PKU-YuanGroup/Open-Sora-Plan/blob/main/docs/Report-v1.1.0.md)中的另一个开源 3D VAE 性能相当。

| 模型          | 结构相似性↑ | 峰值信噪比↑  |
| ------------------ | ----- | ------ |
| Open-Sora-Plan 1.1 | 0.882 | 29.890 |
| Open-Sora 1.2      | 0.880 | 30.590 |

## 整流流和模型适应

最新的扩散模型 Stable Diffusion 3 为了获得更好的性能，采用了[rectified flow](https://github.com/gnobitab/RectifiedFlow)替代了 DDPM。可惜 SD3 的 rectified flow 训练代码没有开源。不过 Open-Sora 1.2 提供了遵循 SD3 论文的训练代码，包括：

- 基本整流流训练
- 用于训练加速的 Logit-norm 采样
- 分辨率和视频长度感知时间步长采样

对于分辨率感知的时间步长采样，我们应该对分辨率较大的图像使用更多的噪声。我们将这个想法扩展到视频生成，对长度较长的视频使用更多的噪声。

Open-Sora 1.2 从[PixArt-Σ 2K](https://github.com/PixArt-alpha/PixArt-sigma) 模型checkpoint开始。请注意，此模型使用 DDPM 和 SDXL VAE 进行训练，分辨率也高得多。我们发现在小数据集上进行微调可以轻松地使模型适应我们的视频生成设置。适应过程如下，所有训练都在 8 个 GPU 上完成：

1. 多分辨率图像生成能力：我们训练模型以 20k 步生成从 144p 到 2K 的不同分辨率。
2. QK-norm：我们将 QK-norm 添加到模型中并训练 18k 步。
3. 整流流：我们从离散时间 DDPM 转变为连续时间整流流并训练 10k 步。
4. 使用 logit-norm 采样和分辨率感知时间步采样的整流流：我们训练 33k 步。
5. 较小的 AdamW epsilon：按照 SD3，使用 QK-norm，我们可以对 AdamW 使用较小的 epsilon（1e-15），我们训练 8k 步。
6. 新的 VAE 和 fps 调节：我们用自己的 VAE 替换原来的 VAE，并将 fps 调节添加到时间步调节中，我们训练 25k 步。请注意，对每个通道进行规范化对于整流流训练非常重要。
7. 时间注意力模块：我们添加时间注意力模块，其中没有初始化投影层。我们在图像上进行 3k 步训练。
8. 仅针对具有掩码策略的视频的时间块：我们仅在视频上训练时间注意力块，步长为 38k。

经过上述调整后，我们就可以开始在视频上训练模型了。上述调整保留了原始模型生成高质量图像的能力，并未后续的视频生成提供了许多助力：

- 通过整流，我们可以加速训练，将视频的采样步数从100步减少到30步，大大减少了推理的等待时间。
- 使用 qk-norm，训练更加稳定，并且可以使用积极的优化器。
- 采用新的VAE，时间维度压缩了4倍，使得训练更加高效。
- 该模型具有多分辨率图像生成能力，可以生成不同分辨率的视频。

## 更多数据和更好的多阶段训练

由于计算预算有限，我们精心安排了训练数据的质量从低到高，并将训练分为三个阶段。我们的训练涉及 12x8 GPU，总训练时间约为 2 周， 约70k步。

### 第一阶段

我们首先在 Webvid-10M 数据集（40k 小时）上训练模型，共 30k 步（2 个 epoch）。由于视频分辨率均低于 360p 且包含水印，因此我们首先在此数据集上进行训练。训练主要在 240p 和 360p 上进行，视频长度为 2s~16s。我们使用数据集中的原始字幕进行训练。训练配置位于[stage1.py](/configs/opensora-v1-2/train/stage1.py)中。

### 第二阶段

然后我们在 Panda-70M 数据集上训练模型。这个数据集很大，但质量参差不齐。我们使用官方的 30M 子集，其中的片段更加多样化，并过滤掉美学评分低于 4.5 的视频。这产生了一个 20M 子集，包含 41k 小时。数据集中的字幕直接用于我们的训练。训练配置位于[stage2.py](/configs/opensora-v1-2/train/stage2.py)中。

训练主要在 360p 和 480p 上进行。我们训练模型 23k 步，即 0.5 个 epoch。训练尚未完成，因为我们希望我们的新模型能早日与大家见面。

### 第三阶段

在此阶段，我们从各种来源收集了 200 万个视频片段，总时长 5000 小时，其中包括：

- 来自 Pexels、Pixabay、Mixkit 等的免费授权视频。
- [MiraData](https://github.com/mira-space/MiraData)：一个包含长视频的高质量数据集，主要来自游戏和城市/风景探索。
- [Vript](https://github.com/mutonix/Vript/tree/main)：一个密集注释的数据集。
- 还有一些其他数据集。

MiraData 和 Vript 有来自 GPT 的字幕，而我们使用[PLLaVA](https://github.com/magic-research/PLLaVA)为其余字幕添加字幕。与只能进行单帧/图像字幕的 LLaVA 相比，PLLaVA 是专门为视频字幕设计和训练的。[加速版PLLaVA](/tools/caption/README.md#pllava-captioning)已在我们的`tools/`中发布。在实践中，我们使用预训练的 PLLaVA 13B 模型，并从每个视频中选择 4 帧生成字幕，空间池化形状为 2*2。

下面显示了此阶段使用的视频数据的一些统计数据。我们提供了持续时间和分辨率的基本统计数据，以及美学分数和光流分数分布。我们还从视频字幕中提取了对象和动作的标签并计算了它们的频率。
![stats](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/report-03_video_stats.png)
![object_count](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/report-03_objects_count.png)
![object_count](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/report-03_actions_count.png)

此阶段我们主要在 720p 和 1080p 上进行训练，以提高模型在高清视频上的表现力。在训练中，我们使用的掩码率为25%。训练配置位于[stage3.py](/configs/opensora-v1-2/train/stage3.py)中。我们对模型进行 15k 步训练，大约为 2 个 epoch。

## 简单有效的模型调节

对于第 3 阶段，我们计算每个视频片段的美学分数和运动分数。但是，由于视频片段数量较少，我们不愿意过滤掉得分较低的片段，这会导致数据集较小。相反，我们将分数附加到字幕中并将其用作条件。我们发现这种方法可以让模型了解分数并遵循分数来生成质量更好的视频。

例如，一段美学评分为 5.5、运动评分为 10 且检测到摄像头运动向左平移的视频，其字幕将为：

```plaintext
[Original Caption] aesthetic score: 5.5, motion score: 10, camera motion: pan left.
```

在推理过程中，我们还可以使用分数来调节模型。对于摄像机运动，我们仅标记了 13k 个具有高置信度的剪辑，并且摄像机运动检测模块已在我们的工具中发布。

## 评估

之前，我们仅通过人工评估来监控训练过程，因为 DDPM 训练损失与生成的视频质量没有很好的相关性。但是，对于校正流，如 SD3 中所述，我们发现训练损失与生成的视频质量有很好的相关性。因此，我们跟踪了 100 张图像和 1k 个视频的校正流评估损失。

我们从 pixabay 中抽样了 1k 个视频作为验证数据集。我们计算了不同分辨率（144p、240p、360p、480p、720p）下图像和不同长度的视频（2s、4s、8s、16s）的评估损失。对于每个设置，我们等距采样 10 个时间步长。然后对所有损失取平均值。

![Evaluation Loss](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/report_val_loss.png)
![Video Evaluation Loss](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/report_vid_val_loss.png)

此外，我们还会在训练过程中跟踪[VBench](https://vchitect.github.io/VBench-project/)得分。VBench 是用于短视频生成的自动视频评估基准。我们用 240p 2s 视频计算 vbench 得分。这两个指标验证了我们的模型在训练过程中持续改进。

![VBench](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/report_vbench_score.png)

所有评估代码均发布在`eval`文件夹中。查看[评估指南](/eval/README.md)了解更多详细信息。

|模型        | 总得分 | 质量得分 | 语义分数 |
| -------------- | ----------- | ------------- | -------------- |
| Open-Sora V1.0 | 75.91%      | 78.81%        | 64.28%         |
| Open-Sora V1.2 | 79.23%      | 80.71%        | 73.30%         |

## 序列并行

我们使用序列并行来支持长序列训练和推理。我们的实现基于Ulysses，工作流程如下所示。启用序列并行后，我们只需要将 `all-to-all` 通信应用于STDiT中的空间模块（spatial block），因为在序列维度上，只有对空间信息的计算是相互依赖的。

![SP](https://github.com/hpcaitech/Open-Sora-Demo/blob/main/readme/sequence_parallelism.jpeg)

目前，由于训练数据分辨率较小，我们尚未使用序列并行进行训练，我们计划在下一个版本中使用。至于推理，我们可以使用序列并行，以防您的 GPU 内存不足。下表显示，序列并行可以实现加速：

| 分辨率 | 时长 | GPU数量 | 是否启用序列并行 |用时（秒） | 加速效果/GPU |
| ---------- | ------- | -------------- | --------- | ------------ | --------------- |
| 720p       | 16秒     | 1              | 否        | 547.97       | -               |
| 720p       | 16s秒    | 2              | 是        | 244.38       | 12%             |

