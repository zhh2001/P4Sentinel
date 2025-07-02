import logging
import warnings

from p4utils.utils.helper import load_topo
from p4utils.utils.sswitch_p4runtime_API import SimpleSwitchP4RuntimeAPI
from p4utils.utils.sswitch_thrift_API import SimpleSwitchThriftAPI

logging.basicConfig(level=logging.INFO, format='[%(asctime)s %(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
warnings.filterwarnings('ignore', category=DeprecationWarning)
warnings.filterwarnings('ignore', category=FutureWarning)

STRATEGY_DIRECT = 1
STRATEGY_WARM_UP = 2

SWITCH_IP = '10.120.21.77'

def main():
    topo = load_topo(json_path='./topology.json')
    grpc_controller = SimpleSwitchP4RuntimeAPI(
        device_id=1,
        grpc_port=50001,
        grpc_ip=SWITCH_IP,
        p4rt_path='./main_p4rt.txt',
        json_path='./main.json'
    )
    thrift_controller = SimpleSwitchThriftAPI(
        thrift_port=10001,
        thrift_ip=SWITCH_IP,
        json_path='./main.json'
    )

    grpc_controller.table_clear('ipv4_lpm')
    grpc_controller.table_set_default('ipv4_lpm', 'drop')
    grpc_controller.table_add('ipv4_lpm', 'ipv4_forward', ['10.0.0.1/32'], ['00:00:0a:00:00:01', '1'])
    grpc_controller.table_add('ipv4_lpm', 'ipv4_forward', ['10.0.0.2/32'], ['00:00:0a:00:00:02', '2'])

    grpc_controller.table_clear('rule_tbl')
    h2_ip = topo.get_host_ip('h2')
    h2_id = 1
    h2_strategy = STRATEGY_WARM_UP
    h2_threshold = 100
    h2_warm_up_period_ms = 5000000
    h2_warm_up_factor = 2
    grpc_controller.table_add('rule_tbl', 'flow_control', [h2_ip],
                              [str(h2_id), str(h2_strategy), '1', str(h2_threshold), str(h2_warm_up_period_ms), str(h2_warm_up_factor), '1000000'])
    warm_up_ms_per_threshold = h2_warm_up_period_ms // (h2_threshold - (h2_threshold >> h2_warm_up_factor))
    thrift_controller.register_write('warm_up_ms_per_threshold', h2_id, int(warm_up_ms_per_threshold))
    # print(thrift_controller.register_read('warm_up_ms_per_threshold', h2_id))

    def listen_count():
        digest_name = 'reported_data'
        if grpc_controller.digest_get_conf(digest_name) is None:
            grpc_controller.digest_enable(digest_name)
        while True:
            digest = grpc_controller.get_digest_list()
            counter_data = digest.data[0].struct.members
            counter_data = (int.from_bytes(counter.bitstring, 'big', signed=False)
                            for counter in counter_data)
            passed_count, blocked_count = counter_data
            logging.info(f"【Direct】接受数量：{passed_count}，拒接数量{blocked_count}")

    def listen_threshold():
        digest_name = 'warm_up_data'
        if grpc_controller.digest_get_conf(digest_name) is None:
            grpc_controller.digest_enable(digest_name)
        while True:
            digest = grpc_controller.get_digest_list()
            warm_up_data = digest.data[0].struct.members
            warm_up_data = (int.from_bytes(counter.bitstring, 'big', signed=False)
                            for counter in warm_up_data)
            threshold, passed_count, blocked_count = warm_up_data
            logging.info(f"【WarmUp】接受数量：{passed_count}，拒接数量{blocked_count}")

    if h2_strategy == STRATEGY_DIRECT:
        listen_count()
    elif h2_strategy == STRATEGY_WARM_UP:
        listen_threshold()


if __name__ == '__main__':
    main()
