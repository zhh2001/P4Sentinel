#ifndef _INGRESS_P4_
#define _INGRESS_P4_

#ifndef V1MODEL_VERSION
#define V1MODEL_VERSION 20200408
#endif

#include <core.p4>
#include <v1model.p4>

#include "headers.p4"

typedef bit<8>  ID_t;
typedef bit<64> packetCount_t;
typedef bit<48> timestamp_t;
typedef bit<8>  tokenCalculateStrategy_t;
typedef bit<8>  controlBehavior_t;
typedef packetCount_t threshold_t;
typedef timestamp_t   warmUpPeriodSec_t;
typedef bit<16>       warmUpColdFactor_t;
typedef timestamp_t   statIntervalInMs_t;

// 熔断规则
typedef bit<8>                   breakerStatue_t;
typedef timestamp_t              retryTimeout_t;
typedef tokenCalculateStrategy_t recoveryStrategy_t;
typedef timestamp_t              recoveryPeriod_t;
typedef packetCount_t            warmUpRate_t;

const tokenCalculateStrategy_t STRATEGY_DIRECT  = 1;
const tokenCalculateStrategy_t STRATEGY_WARM_UP = 2;

const recoveryStrategy_t RECOVERY_STRATEGY_DIRECT  = 1;
const recoveryStrategy_t RECOVERY_STRATEGY_WARM_UP = 2;

const controlBehavior_t BEHAVIOR_REJECT     = 1;
const controlBehavior_t BEHAVIOR_THROTTLING = 2;

// state constants
const breakerStatue_t STATE_CLOSED    = 0;
const breakerStatue_t STATE_OPEN      = 1;
const breakerStatue_t STATE_HALF_OPEN = 2;

register<packetCount_t, ID_t>(2 << 8) passed;
register<packetCount_t, ID_t>(2 << 8) blocked;
register<timestamp_t, ID_t>(2 << 8) timestamp;

register<threshold_t, ID_t>(2 << 8) warm_up_threshold;  // 预热模式下的真实阈值
register<timestamp_t, ID_t>(2 << 8) warm_up_update_timestamp;  // 更新预热阈值的时间
register<timestamp_t, ID_t>(2 << 8) warm_up_ms_per_threshold;  // 预热/冷启动后每多少微秒后增加一个阈值

register<breakerStatue_t, ID_t>(2 << 8) breaker_statue;  // 各个微服务的熔断器状态
register<timestamp_t, ID_t>(2 << 8) breaker_open_timestamp;  // 熔断器进入 Open 的时间戳
register<timestamp_t, ID_t>(2 << 8) breaker_half_open_timestamp;  // 熔断器进入 Half-Open 的时间戳，用于预热恢复
register<bit<1>, ID_t>(2 << 8) breaker_will_open;  // 熔断器进入 open 的标记

struct reported_data {
    packetCount_t passed;
    packetCount_t blocked;
}

struct warm_up_data {
    threshold_t threshold;
    packetCount_t passed;
    packetCount_t blocked;
}

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    action flow_control(
        ID_t                     id,
        tokenCalculateStrategy_t tokenCalculateStrategy,
        controlBehavior_t        controlBehavior,
        threshold_t              threshold,
        warmUpPeriodSec_t        warmUpPeriodSec,
        warmUpColdFactor_t       warmUpColdFactor,
        statIntervalInMs_t       statIntervalInMs
    ) {
        packetCount_t passed_count;
        passed.read(passed_count, id);

        packetCount_t blocked_count;
        blocked.read(blocked_count, id);

        timestamp_t start_timestamp;
        timestamp.read(start_timestamp, id);

        if (tokenCalculateStrategy == STRATEGY_DIRECT) {
            if (controlBehavior == BEHAVIOR_REJECT) {
                // 判断时间窗口
                if (standard_metadata.ingress_global_timestamp - start_timestamp >= statIntervalInMs) {
                    // 报告数据
                    reported_data data;
                    data.passed = passed_count;
                    data.blocked = blocked_count;
                    digest<reported_data>(1, data);

                    passed_count = 0;
                    blocked_count = 0;
                    passed.write(id, passed_count);
                    blocked.write(id, blocked_count);
                    timestamp.write(id, standard_metadata.ingress_global_timestamp);
                }

                // 判断阈值
                if (passed_count < threshold) {
                    passed.write(id, passed_count + 1);
                } else {
                    blocked.write(id, blocked_count + 1);
                    mark_to_drop(standard_metadata);
                }
            }
        } else if (tokenCalculateStrategy == STRATEGY_WARM_UP) {
            // 预热/冷启动
            threshold_t real_threshold;
            warm_up_threshold.read(real_threshold, id);

            // 获取每个阈值提升需要的秒数
            timestamp_t ms_per_threshold;
            warm_up_ms_per_threshold.read(ms_per_threshold, id);

            // 获取真实阈值更新的时间
            timestamp_t update_timestamp;
            warm_up_update_timestamp.read(update_timestamp, id);

            if (update_timestamp == 0) {
                // 当第一个数据包进来的时候，触发预热开始
                warm_up_update_timestamp.write(id, standard_metadata.ingress_global_timestamp);

                // 基础阈值 = 设定阈值 / 2 ** 预热因子
                threshold_t base_threshold;
                base_threshold = threshold >> (bit<8>) warmUpColdFactor;
                warm_up_threshold.write(id, base_threshold);
                real_threshold = base_threshold;
            } else {
                // 每次数据包进来，都判断超出触发阈值更新的时间了吗，超过就上调一次阈值
                timestamp_t timestamp_diff;
                timestamp_diff = standard_metadata.ingress_global_timestamp - update_timestamp;
                if (timestamp_diff >= ms_per_threshold && real_threshold < threshold) {
                    warm_up_update_timestamp.write(id, standard_metadata.ingress_global_timestamp);
                    warm_up_threshold.write(id, real_threshold + 1);

                    // 每次调整阈值，记录一下
                    warm_up_data data;
                    data.threshold = real_threshold + 1;
                    data.passed = passed_count;
                    data.blocked = blocked_count;
                    digest<warm_up_data>(1, data);
                }
            }

            // 判断时间窗口
            if (standard_metadata.ingress_global_timestamp - start_timestamp >= statIntervalInMs) {
                // 报告数据
                warm_up_data data;
                data.threshold = real_threshold;
                data.passed = passed_count;
                data.blocked = blocked_count;
                digest<warm_up_data>(1, data);

                passed_count = 0;
                blocked_count = 0;
                passed.write(id, passed_count);
                blocked.write(id, blocked_count);
                timestamp.write(id, standard_metadata.ingress_global_timestamp);
            }

            // 判断阈值
            if (passed_count < real_threshold) {
                passed.write(id, passed_count + 1);
            } else {
                blocked.write(id, blocked_count + 1);
                mark_to_drop(standard_metadata);
            }
        }
    }

    action circuit_breaking(
        ID_t               id,
        retryTimeout_t     retryTimeout,
        threshold_t        threshold,
        recoveryStrategy_t recoveryStrategy,
        recoveryPeriod_t   recoveryPeriod,
        warmUpRate_t       warmUpRate
    ) {
        // 获取当前微服务的熔断器状态
        breakerStatue_t statue;
        breaker_statue.read(statue, id);

        if (statue == STATE_CLOSED) {  // 熔断器处于关闭状态
            // 获取是否需要启动熔断器的指示
            bit<1> will_open;
            breaker_will_open.read(will_open, id);

            if (will_open == 1) {  // 启动熔断器
                statue = STATE_OPEN;
                breaker_statue.write(id, statue);
                breaker_open_timestamp.write(id, standard_metadata.ingress_global_timestamp);
                breaker_will_open.write(id, 0);
            }
        }

        if (statue == STATE_OPEN) {  // 熔断器处于打开状态
            timestamp_t open_timestamp;
            breaker_open_timestamp.read(open_timestamp, id);
            if (standard_metadata.ingress_global_timestamp - open_timestamp >= retryTimeout) {
                statue = STATE_HALF_OPEN;
                breaker_statue.write(id, statue);
                breaker_half_open_timestamp.write(id, standard_metadata.ingress_global_timestamp);
            } else {
                drop();
            }
        }

        if (statue == STATE_HALF_OPEN) {  // 熔断器处于半开状态
            timestamp_t half_open_timestamp, microseconds;
            breaker_half_open_timestamp.read(half_open_timestamp, id);
            microseconds = standard_metadata.ingress_global_timestamp - half_open_timestamp;

            // 超过恢复时长，微服务无问题，则可直接恢复
            if (microseconds >= recoveryPeriod) {
                statue = STATE_CLOSED;
                breaker_statue.write(id, statue);
            } else {
                packetCount_t passed_count;
                passed.read(passed_count, id);
                if (recoveryStrategy == RECOVERY_STRATEGY_DIRECT) {
                    if (passed_count >= threshold) {
                        drop();
                    }
                } else if (recoveryStrategy == RECOVERY_STRATEGY_WARM_UP) {
                    if (passed_count >= threshold + (microseconds >> 16) * warmUpRate) {
                        drop();
                    }
                }
            }
        }
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
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

    // 熔断器表
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
            ipv4_lpm.apply();
            rule_tbl.apply();
            circuit_state_tbl.apply();
        }
    }
}

#endif  /* _INGRESS_P4_ */
