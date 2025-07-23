# P4Sentinel

P4Sentinel 是一个基于 P4 可编程数据平面的微服务流量治理原型系统，旨在将原本部署在服务端的流控逻辑迁移到交换机层执行，实现更高性能、低延迟的分布式限流能力。

本项目复刻并简化了 Alibaba Sentinel 的核心流控机制，并对其进行数据平面友好化改造，适用于服务集群前置部署的可编程交换机场景。

## 流量控制

### 规则说明

在 Sentinel 中，流控规则以如下 Go 结构体表示：

```golang
type Rule struct {
	ID                     string                 `json:"id,omitempty"`
	Resource               string                 `json:"resource"`
	TokenCalculateStrategy TokenCalculateStrategy `json:"tokenCalculateStrategy"`
	ControlBehavior        ControlBehavior        `json:"controlBehavior"`
	Threshold              float64                `json:"threshold"`
	RelationStrategy       RelationStrategy       `json:"relationStrategy"`
	RefResource            string                 `json:"refResource"`
	MaxQueueingTimeMs      uint32                 `json:"maxQueueingTimeMs"`
	WarmUpPeriodSec        uint32                 `json:"warmUpPeriodSec"`
	WarmUpColdFactor       uint32                 `json:"warmUpColdFactor"`
	StatIntervalInMs       uint32                 `json:"statIntervalInMs"`
}
```

一条 Sentinel 流控规则包含以下主要字段，可通过不同组合实现丰富的限流策略：

- `Resource`：资源名称，即当前规则生效的对象，通常为某个接口。
- `TokenCalculateStrategy`: 当前流量控制器的 Token 计算策略，支持：
  - `Direct`：表示直接使用字段 `Threshold` 作为限流阈值；
  - `WarmUp`：表示使用预热方式计算 Token 的阈值。
- `ControlBehavior`: 表示流量控制器的控制行为：
  - `Reject`：表示超过阈值直接拒绝；
  - `Throttling`：表示匀速排队。
- `Threshold`: 表示流控阈值；如果 `StatIntervalInMs=1000`，也就是 1 秒，那么 Threshold就表示 QPS，流量控制器也就会依据资源的 QPS 来做流控。
- `RelationStrategy`: 调用关系限流策略，CurrentResource 表示使用当前规则的 resource 做流控；AssociatedResource 表示使用关联的 resource 做流控，关联的 resource 在字段 `RefResource` 定义；
- `RefResource`: 关联的 resource；
- `WarmUpPeriodSec`: 预热的时间长度，该字段仅仅对 `WarmUp` 的 TokenCalculateStrategy 生效；
- `WarmUpColdFactor`: 预热的因子，默认是 3，该值的设置会影响预热的速度，该字段仅仅对 `WarmUp` 的 TokenCalculateStrategy 生效；
- `MaxQueueingTimeMs`: 匀速排队的最大等待时间，该字段仅仅对 `Throttling` ControlBehavior 生效；
- `StatIntervalInMs`: 规则的统计时间窗口（单位为毫秒），决定了限流器的粒度与灵敏度。

### P4Sentinel 中的字段映射

在 P4Sentinel 中，部分字段含义被重新解释和简化，以适应 P4 数据平面编程限制，当前实现阶段未使用关联资源与排队控制相关字段，目的是降低数据平面逻辑复杂度，便于快速验证系统设计。

主要区别如下：

- `Resource`：表示被限流的微服务标识。若微服务部署在独立服务器上，则可使用目的 IP 作为匹配标识；若同一主机上部署多个微服务，则可通过 IP + Port 组合字段唯一识别服务。
- `TokenCalculateStrategy`: 与 Sentinel 相同，支持 `Direct` 与 `WarmUp` 两种模式。
- `ControlBehavior`: 当前仅支持 `Reject` 策略，即在超过阈值时直接丢弃数据包。
- `Threshold`: 表示限流阈值。不同于 Sentinel 以 QPS 为单位，P4Sentinel 中为数据平面设计，统计的是包速率（PPS）。若 `StatIntervalInMs` 为 1000000 微秒（1 秒），则阈值表示允许的 PPS。
- `WarmUpPeriodSec`: 用于 WarmUp 模式下的预热时长，单位为微秒（us）。因为在 P4Sentinel 中，实现为基于时间推进的分段阈值增长，每次阈值上升都依赖数据包经过 Ingress Pipeline，实际预热结束时间会略高于设定值。
- `WarmUpColdFactor`: 表示冷启动阶段的限速比例控制，值越大，系统初期释放速率越低，由于 P4 特性，此处将初始阈值的计算设置为 `Threshold >> WarmUpColdFactor`。
- `StatIntervalInMs`: 表示计数器统计周期，单位为微秒（us）。其值直接影响限流判断精度与响应速度。

### Rule 流表设计

为简化验证流程，P4Sentinel 实验原型假设每个微服务均部署于独立服务器中，服务器构成服务集群，P4Sentinel 程序运行于集群的入口交换机上。

以下为简化版本的 `rule_tbl` 表定义：

```p4
    action flow_control(
        ID_t                     id,
        tokenCalculateStrategy_t tokenCalculateStrategy,
        controlBehavior_t        controlBehavior,
        threshold_t              threshold,
        warmUpPeriodSec_t        warmUpPeriodSec,
        warmUpColdFactor_t       warmUpColdFactor,
        statIntervalInMs_t       statIntervalInMs
    ) {
        ...
    }

    table rule_tbl {
        key = {
            hdr.ipv4.dstAddr: exact;
        }
        actions = {
            flow_control;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }

    apply {
        if (hdr.ipv4.isValid()){
            rule_tbl.apply();
        }
    }
```

## 熔断降级

基于微服务自上报指标驱动的 P4Sentinel 熔断器机制。由微服务自行统计接口的错误率或者响应时延等等指标，达到一定阈值自行向 P4Runtime-based 控制器上报。控制器采取可自定义的熔断措施，熔断规则在后面详细解释。

建议微服务的统计支持静默期，静默期是指一个最小的静默请求数，在一个统计周期内，如果对资源的请求数小于设置的静默数，那么熔断器将不会基于其统计值去更改熔断器的状态。静默期的设计理由也很简单，举个例子，假设在一个统计周期刚刚开始时候，第 1 个请求碰巧是个慢请求，这个时候这个时候的慢调用比例就会是 100%，很明显是不合理，所以存在一定的巧合性。所以静默期提高了熔断器的精准性以及降低误判可能性。

### 规则说明

在 Sentinel 中，熔断规则以如下 Go 结构体表示：

```go
type Rule struct {
	Id               string   `json:"id,omitempty"`
	Resource         string   `json:"resource"`
	Strategy         Strategy `json:"strategy"`
	RetryTimeoutMs   uint32   `json:"retryTimeoutMs"`
	MinRequestAmount uint64   `json:"minRequestAmount"`
	StatIntervalMs   uint32   `json:"statIntervalMs"`
	MaxAllowedRtMs   uint64   `json:"maxAllowedRtMs"`
	Threshold        float64  `json:"threshold"`
}
```

一条 Sentinel 熔断规则包含以下主要字段，可通过不同组合实现丰富的熔断策略：

- `Resource`：熔断器规则生效的埋点资源的名称。
- `Strategy`：熔断策略，目前支持 `SlowRequestRatio`、`ErrorRatio`、`ErrorCount` 三种。
- `RetryTimeoutMs`：即熔断触发后持续的时间（单位为 ms）。资源进入熔断状态后，在配置的熔断时长内，请求都会快速失败。熔断结束后进入探测恢复模式（HALF-OPEN）。
- `MinRequestAmount`：静默数量，如果当前统计周期内对资源的访问数量小于静默数量，那么熔断器就处于静默期。换言之，也就是触发熔断的最小请求数目，若当前统计周期内的请求数小于此值，即使达到熔断条件规则也不会触发。
- `StatIntervalMs`：统计的时间窗口长度（单位为 ms）。
- `MaxAllowedRtMs`：仅对 `慢调用熔断策略` 生效，MaxAllowedRtMs 是判断请求是否是慢调用的临界值，也就是如果请求的 response time 小于或等于 MaxAllowedRtMs，那么就不是慢调用；如果 response time 大于 MaxAllowedRtMs，那么当前请求就属于慢调用。
- `Threshold`：对于 `慢调用熔断策略`, Threshold 表示是慢调用比例的阈值，也就是如果当前资源的慢调用比例如果高于 Threshold，那么熔断器就会断开；否则保持闭合状态。 对于 `错误比例策略`，Threshold 表示的是错误比例的阈值。对于 `错误数策略`，Threshold 是错误计数的阈值。

### P4Sentinel 中的字段映射

在 P4Sentinel 中，部分字段含义被重新解释和简化，以适应 P4 数据平面编程限制，当前实现阶段仅由微服务统计错误率和时延是否超过阈值，主动向控制器上报，目的是降低数据平面逻辑复杂度，便于快速验证系统设计。

所以暂时不存在 Sentinel 中的 `Strategy`、`MinRequestAmount`、`StatIntervalMs`、`MaxAllowedRtMs`、`Threshold`

后续会考虑取消微服务主动上报的形式，完全由数据平面来判断是否熔断，例如在 P4 交换机上收集 TCP RST 报文计数（连接被拒）、ICMP Unreachable 报文、可通过 INT 或 eBPF 辅助收集如 gRPC/HTTP 的状态码。

主要区别如下：

- `Resource`：表示被限流的微服务标识。若微服务部署在独立服务器上，则可使用目的 IP 作为匹配标识；若同一主机上部署多个微服务，则可通过 IP + Port 组合字段唯一识别服务。
- `RetryTimeout`：即熔断触发后持续的时间（单位为 μs）。资源进入熔断状态后，在配置的熔断时长内，请求都会快速失败。熔断结束后进入探测恢复模式（HALF-OPEN）。
- `Threshold`: 表示进入 HALF-OPEN 状态后，以什么包速率放行试探流量，单位 pps。
- `RecoveryStrategy`：熔断后的恢复策略，即从 HALF-OPEN 转为 CLOSED 后的行为。支持 `Direct` 与 `WarmUp` 两种模式。
- `RecoveryPeriod`: 用于 WarmUp 的恢复模式下的恢复时长，单位为微秒（us）。
- `WarmUpRate`：这个是预热恢复的过程中，多少微秒上升 1 pps。

### Rule 流表设计

为简化验证流程，P4Sentinel 实验原型假设每个微服务均部署于独立服务器中，服务器构成服务集群，P4Sentinel 程序运行于集群的入口交换机上。

以下为简化版本的 `rule_tbl` 表定义：

```p4
    action circuit_breaking(
        ID_t               id,
        retryTimeout_t     retryTimeout,
        threshold_t        threshold,
        recoveryStrategy_t recoveryStrategy,
        recoveryPeriod_t   recoveryPeriod,
        warmUpRate_t       warmUpRate
    ) {
        ...
    }

    table circuit_state_tbl {
        key = {
            hdr.ipv4.dstAddr: exact;
        }
        actions = {
            circuit_breaking;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }

    apply {
        if (hdr.ipv4.isValid()){
            circuit_state_tbl.apply();
        }
    }
```

## 🚀 项目状态

P4Sentinel 当前已完成基本功能的原型开发，并支持以下特性：

- 基于 P4 的数据平面流量计数与限流判断
- 支持 Direct/WarmUp 两种流控策略
- 控制器下发限流规则与参数
- 精度级别：微秒级统计窗口，纳秒级判断响应

## 📎 联系与贡献

欢迎提交 Issue 与 PR 来改进本项目。
