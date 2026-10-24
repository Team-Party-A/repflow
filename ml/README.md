# 离线传感器数据检查

当前交付只对应 #35 的[录制格式提案](../docs/data/01-sensor-recording-format.md)，不包含计次算法或录制工具。
真实原始数据保存在仓库外；仓库内只有明确标注的合成样例。

在仓库根目录运行，Python 3.9+，脚本无第三方运行依赖：

~~~sh
python3 ml/inspect_recording.py docs/data/samples/synthetic-v1.json
~~~

成功时向标准输出写 JSON，退出码 0；文件、JSON 或契约关键约束错误向标准错误记录原因，退出码 2。
effective_hz 来自真实样本间隔，requested_hz 只表示请求值；known_complete_events 不等于未经确认的整组真值。
脚本检查本契约列出的关键结构/数值约束，不验证真实运动是否符合标注，也不替代匿名化人工复核。

使用已安装的开发工具：

~~~sh
ruff format --check ml
ruff check ml
pytest ml
~~~

本次验证可用隔离工具运行，不向项目新增依赖或改 CI：

~~~sh
uvx --python 3.14 --from ruff==0.17.2 ruff format --check ml
uvx --python 3.14 --from ruff==0.17.2 ruff check ml
uvx --python 3.14 --from pytest==9.1.1 pytest ml
~~~
