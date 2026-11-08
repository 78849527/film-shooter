# FilmShooter 系统照片编辑扩展

本扩展随主 App 安装，并在 iOS 16.5+「照片」→ 选择照片 →「编辑」→「···」中出现。

- 直接复用 FilmCatalog / DevelopRecipe / FilmEngine / PhotoDecoder，不使用系统照片滤镜来代替光谱模拟。
- 仅支持静态图片；Live Photo 与视频不在此扩展的媒体类型中。
- 预览使用照片编辑输入的显示尺寸图片，渲染结果和对应配方一次性发布；只接纳当前操作序号的结果。
- 「完成」时读取 fullSizeImageURL，从原始分辨率数据准备 4096 像素长边以内的导出帧，输出 JPEG 到系统提供的 renderedContentURL；大图为控制扩展内存会降至 4096 像素长边。
- PHAdjustmentData 记录完整配方，重新进入本扩展可再编辑。交由系统照片管理回退与编辑历史。
- 系统照片里的曝光、鲜明度、高光、阴影、裁剪继续通过苹果自己的编辑 UI 处理，不在 FilmShooter 中重复实现。
- 最低系统版本 iOS 16.5；需检查 XcodeGen 工程正确嵌入 PlugIns/FilmShooterPhotoEditExtension.appex，且扩展独立包含 EngineResources 文件夹。
- 不使用 app group、跨进程文件共享或照片图库写入权限。扩展只访问 Apple 提供的编辑输入与输出 URL。
- 只修改 `fix/ios16-5-1-compat`，不合并主分支。

## 真机验收

1. 打开「照片」原图，通过「编辑」→「···」找到 FilmShooter 胶片扩展。
2. 选择 Portra 400 / Gold 200 / Vision3 / Tri-X；确认预览和名称同步，切换黑白/反转时相纸适配。
3. 选择相纸、调节颗粒和光晕后保存，回到系统照片用「鲜明度」精修。
4. 返回扩展重新进入，确认此前胶卷与参数能从 PHAdjustmentData 恢复；再选择新胶卷时相纸保持。
5. 测试 HEIC/JPEG 横竖拍、RAW、已有苹果编辑的照片及照片复原；检查旋转方向和大图内存压力。
