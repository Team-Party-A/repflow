# 传感器录制数据格式 v1.0（评审提案）

关联 #35；依据[计次可行性调研第 4–5 节](../algorithm/计次可行性调研.md)、
[REQ-NFR-405/406](../requirements/04-alg-web.md)。
本稿待负责人确认及 watchOS 负责人 @whj-thu 评审，合入 dev 后冻结。
当前只交格式、小样例和离线检查器；不包含录制工具、真实采集或算法准确率结论。

## 1. 文件与边界

- 一段录制一个 UTF-8 JSON 文件；一段对应一个组或一个负样本场景。多个组分别录制。
- 文件名建议 recording_id.json；recording_id 为匿名、不重复的本地编号，不等同于业务训练或账号 ID。
- 顶层字段见下表；JSON 禁止重复键、NaN、Infinity、布尔值代替数字。至少保留两个有效样本。
- samples 保留收到的原始数值和真实时间间隔，不平滑、不重采样、不插值，不去掉准备/组后数据。
- 本格式用于录制、Python 评估、Swift 回放，不能直接作为手机消息或后端业务 API。

| 顶层字段 | 类型 | 含义 |
| --- | --- | --- |
| format_version | string | 固定为 "1.0"；读取器遇到其他版本须显式拒绝，不能猜测单位或字段含义 |
| recording_id | string | 非空匿名编号，例如 synthetic-001 |
| data_kind | string | synthetic：合成夹具；recorded：真实采集。两者不能混报指标 |
| duration_s | number | 录制结束相对时间，必须大于 0，且不早于最后一个样本 |
| metadata | object | 设备、佩戴、采样和时间元信息 |
| set | object / null | 有效组边界及真值总数；负样本必须显式为 null |
| annotations | array | 人工标注，允许为空 |
| samples | array | 按时间严格递增的运动样本 |

未知的附加字段可忽略，但不能改变已知字段的意义。字段、单位、计次口径或必填性变化须更新版本、
走契约 PR，并经算法和 watchOS 双方确认；既有样本保留其原版本，不静默覆盖。

## 2. 元信息

以下 metadata 字段全部必填，字符串不能留空：

| 字段 | 类型 / 值 | 说明 |
| --- | --- | --- |
| participant_id | string，p001 等 p 加至少三位数字 | 采集前随机分配的匿名编号；身份对应表单独保管，不能入库 |
| recording_kind | exercise_set / negative | 一组动作 / 静止、走动、拿放器械等负样本 |
| activity | string | 本地数据集的动作/场景编号，例如 dumbbell_curl、walking；不冻结产品支持动作清单 |
| worn_wrist | left / right | 佩戴腕；对应 WKInterfaceDevice.wristLocation |
| crown_orientation | left / right | 表冠配置；对应 WKInterfaceDevice.crownOrientation，不自行推断为左/右腕 |
| device.model | string | 实际设备型号；不含设备名、序列号、UDID |
| device.os_version | string | 实际系统版本；不拿最低兼容版本代填真实设备 |
| recorder_version | string | 录制程序可追溯的版本/提交号 |
| requested_hz | positive number | 请求采样率，首轮建议 50 Hz，25 Hz 为对照；不是实测采样率 |
| time_origin | first_motion_sample | 本段第一个有效 CMDeviceMotion 样本为录制时间零点 |
| coordinate_frame | core_motion_device | 三轴数据保持 Core Motion 设备坐标，不做世界坐标变换 |
| attitude_reference_frame | xArbitraryZVertical | Device Motion 会话使用的参考系；不依赖磁北/真北 |
| attitude_recorded | boolean | 本段是否全量记录四元数；false 时每个样本均不含该字段 |

合成样例使用 p000，device.model 为 synthetic、os_version 为 not_applicable；
这些值表示未使用真机，不是任何真实参与者或兼容测试记录。
真实采集的录制程序应记录实际设备/系统；匿名化仍须人工检查，编号格式不能自动保证隐私。

## 3. 时间、坐标与样本

t_s = 当前 CMDeviceMotion.timestamp − 本段首个有效样本的 timestamp，单位秒；
第一个 t_s 必须为 0。Core Motion 的 timestamp 是设备启动后的时间，禁止改用 Date 墙钟、
回调到达时间或“样本下标 ÷ 请求频率”。每段重新取零点，不拼接跨重启/跨录制的绝对时间。

标注与 duration_s 也必须换算到同一单调时间轴。录制按钮按下至首个有效样本前的等待不属于本段；
如用外部视频标注，须先人工对齐零点，不能直接写视频时间或 UTC。
正常组前后尽量各留约 3 秒静止；结束时刻晚于末样本的间隔需要保留，不能假装尾部持续采样。

| 样本字段 | 类型 | 单位及来源 |
| --- | --- | --- |
| t_s | number，非负且严格递增 | 真实样本的相对秒数 |
| user_acceleration_g | [x, y, z]，三项有限数值 | CMDeviceMotion.userAcceleration，去重力用户加速度，单位 g |
| rotation_rate_rad_s | [x, y, z]，三项有限数值 | CMDeviceMotion.rotationRate，经 Core Motion 去偏的角速度，单位 rad/s |
| gravity_g | [x, y, z]，三项有限数值 | CMDeviceMotion.gravity，设备坐标下的重力，单位 g |
| attitude_xyzw | [x, y, z, w]，四项有限数值，可选 | CMDeviceMotion.attitude.quaternion；明确 x/y/z/w 次序，模长平方与 1 的差不超过 0.001 |

三个三轴数组按 API 的 x/y/z 顺序原样写入，不因佩戴腕、表冠配置或界面旋转交换轴、翻转符号、
取绝对值或转成模长。设备坐标与姿态参考系是两件事：前者描述三轴分量，后者定义 attitude 的参考。
不要把 xArbitraryZVertical 的世界 Z 轴直接当作 gravity_g 的设备 Z 轴。

1 g 按 9.80665 m/s² 换算；文件仍保存 g，读取器不暗中换单位。
四元数在同一段中全有或全无，缺失用“省略字段”，不能写 null、零数组或单位四元数冒充测量。
参考系变化、采样会话重启或设备重启应新开文件；跨段绝对姿态不能直接比较。
检查器不归一化/改写输入，也不把 ±q 的等价表示当作运动跳变判断依据。

时间重复、倒序、非法数值应报错，不能排序后悄悄通过。实际采样缺口保留原间隔；
长缺口和尾部停采需结合标注及后续质检判断，不在本契约冻结“丢帧阈值”。

## 4. 有效组和人工标注

exercise_set 的 set 包含 start_s、end_s、ground_truth_count：
0 ≤ start_s < end_s ≤ duration_s。start_s/end_s 分别表示有效计次开始/结束，
不是整个文件起止，也不是稍后的确认保存时刻。准备、组后拿放器械不在有效组内。
negative 的 set 必须为 null；此时 activity 说明负样本场景，不写业务训练次数。

annotations 按 t_s 或 start_s 非递减排列；区间统一为左闭右开 [start_s, end_s)，
且 0 ≤ start_s < end_s ≤ duration_s。区间可以重叠，完整事件不能位于其中。
所有区间都需要非空 reason，内容用场景/异常类别，不写可识别个人信息。

| type | 时间字段 | 含义 |
| --- | --- | --- |
| rep_complete | t_s | 一个完整动作返回约定起始姿态的完成时刻；在组边界内且不可重复 |
| incomplete | start_s、end_s、reason | 未完成的一次，例如半次后结束；必须在有效组内，不计完整次 |
| pause | start_s、end_s、reason | 组内/录制中的停顿，时间轴不扣除这段时长，不因此自动开新组 |
| ambiguous | start_s、end_s、reason | 观察者无法确认真值的区间；保留供复核，不根据算法输出反填 |

一次的定义沿用调研：出发、完成动作、返回约定起始姿态；首批双侧同步动作按完整周期一次。
标注来自独立观察/复核，不来自算法预测，也不从用户组后修正值倒推。

ground_truth_count 为非负整数或 null：
- 已完成真值复核且组内无 ambiguous 时，填写整数，并与 rep_complete 数量完全一致；0 次评估组允许存在。
- 组内存在 ambiguous 时必须为 null，已确认且在这些区间外的 rep_complete 仍可保存。
- 尚未完成总数复核时也填 null；null 不是 0，已确认的事件数不能冒充整组真值总数。
- 暂停、半次、ambiguous 不自动加次；同一完成时刻只能有一个事件。
- 0 次评估组与产品“0 次组不能保存”的规则不同；回放数据绝不能进入真实训练历史、统计或正常上传。

## 5. 样例与读取

[samples/synthetic-v1.json](samples/synthetic-v1.json) 是纯数学合成的 3 秒、151 点样例：
t_s = i / 50（i 从 0 到 150），加速度 x 为 0.35 sin(2πt)，角速度 z 为 0.9 cos(2πt)，
其余运动分量为 0，重力为 [0, 0, -1]。标注只演示序列化，不证明这些波形对应真实动作。
样例含 2 个已确认完成事件、暂停、半次和真值不确定片段，因此整组真值总数为 null；
不满足真实采集前后静止时长，也不用于算法准确率、耗电或兼容性结论。

在仓库根目录执行（Python 3.9+；运行脚本只需标准库）：

~~~sh
python3 ml/inspect_recording.py docs/data/samples/synthetic-v1.json
~~~

检查器输出 JSON：sample_count=151、effective_hz=50、duration_s=3、
known_complete_events=2、ground_truth_count=null；时间间隔中位数约 0.02 秒。
有效采样率按 (N−1)/(最后时间−首个时间) 计算，不能用 N/时长；
另外报告最小/中位/最大间隔、observed_span_s 和 tail_gap_s，供缺口质检。
平均频率正常不能证明连续采样正常；检查器不估算补帧数，不执行动作计数。

## 6. 数据存放与冻结验收

真实数据（即使只有匿名号）、身份映射、可识别视频、设备标识和原始录制备份均不进 Git。
在仓库外私有目录保存；存放位置、访问范围及保留期由团队在采集前确认。
仅本次明确标为 synthetic 的小夹具作为契约样例入库；不要把它当成真实数据的上传入口。

| #35 验收项 | 本次对应交付 |
| --- | --- |
| 文件、字段、单位、坐标、时间、元信息与版本 | 第 1–3 节 |
| 完成、组边界、暂停、不确定真值 | 第 4 节 |
| 调研第 4 节信号与设备/程序信息 | metadata、三个三轴字段、可选四元数 |
| 无个人信息的几秒样例与实测频率读取 | 合成样例、inspect_recording.py 及单元测试 |
| watchOS 10 可输出 | 待 @whj-thu 审查；未执行真机录制或落腕持续采样 |
| 合入即冻结 | 当前为评审提案；需负责人确认、非作者批准后由人合入 |

待双方确认：单文件 JSON、时间零点及末尾停采表示、三轴单位/原样坐标、四元数可选性、
标注边界与 null 真值规则。以上作为本 PR 的具体提案，未绕过契约评审自行冻结。
后续录制工具须用本样例与 Python 检查器对齐，并以 watchOS 10 真机验证实际输出、采样及落腕表现。

依据为 Apple 官方文档及现有调研，API 存在不能替代真机验收：
[CMLogItem.timestamp](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp)、
[CMAcceleration](https://developer.apple.com/documentation/coremotion/cmacceleration)、
[CMRotationRate](https://developer.apple.com/documentation/coremotion/cmrotationrate)、
[gravity](https://developer.apple.com/documentation/coremotion/cmdevicemotion/gravity)、
[xArbitraryZVertical](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe/xarbitraryzvertical)。
