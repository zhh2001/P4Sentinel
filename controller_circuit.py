import asyncio
import logging
import warnings
from typing import Final
from typing import Optional

import networkx as nx
import tornado
from p4utils.utils.helper import load_topo
from p4utils.utils.sswitch_p4runtime_API import SimpleSwitchP4RuntimeAPI
from p4utils.utils.sswitch_thrift_API import SimpleSwitchThriftAPI

logging.basicConfig(level=logging.INFO, format='[%(asctime)s %(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
warnings.filterwarnings('ignore', category=DeprecationWarning)
warnings.filterwarnings('ignore', category=FutureWarning)

STRATEGY_DIRECT = 1
STRATEGY_WARM_UP = 2

BEHAVIOR_REJECT = 1
BEHAVIOR_THROTTLING = 2

STATE_CLOSED = 0
STATE_OPEN = 1
STATE_HALF_OPEN = 2

SWITCH_IP: Final[str] = '10.120.21.77'

topo: Final[nx.Graph] = load_topo(json_path='./topology.json')
grpc_controller: Optional[SimpleSwitchP4RuntimeAPI] = None
thrift_controller: Optional[SimpleSwitchThriftAPI] = None


def init_controller():
    global grpc_controller
    global thrift_controller
    if grpc_controller is None:
        grpc_controller = SimpleSwitchP4RuntimeAPI(
            device_id=1,
            grpc_port=50001,
            grpc_ip=SWITCH_IP,
            p4rt_path='./main_p4rt.txt',
            json_path='./main.json'
        )
    if thrift_controller is None:
        thrift_controller = SimpleSwitchThriftAPI(
            thrift_port=10001,
            thrift_ip=SWITCH_IP,
            json_path='./main.json'
        )


def ip_forwarding(table_name: str = 'ipv4_lpm'):
    logging.log(logging.DEBUG, f'table_clear {table_name}')
    grpc_controller.table_clear(table_name)

    logging.log(logging.DEBUG, f'table_set_default {table_name} drop')
    grpc_controller.table_set_default(table_name, 'drop')

    logging.log(logging.DEBUG, f'table_add {table_name} ipv4_forward 10.0.0.1/32 => 00:00:0a:00:00:01 1')
    grpc_controller.table_add(table_name, 'ipv4_forward', ['10.0.0.1/32'], ['00:00:0a:00:00:01', '1'])

    logging.log(logging.DEBUG, f'table_add {table_name} ipv4_forward 10.0.0.2/32 => 00:00:0a:00:00:02 2')
    grpc_controller.table_add(table_name, 'ipv4_forward', ['10.0.0.2/32'], ['00:00:0a:00:00:02', '2'])


def flow_control(table_name: str = 'rule_tbl'):
    logging.log(logging.DEBUG, f'table_clear {table_name}')
    grpc_controller.table_clear(table_name)

    h2_ip = topo.get_host_ip('h2')
    h2_id = 1
    h2_strategy = STRATEGY_DIRECT
    h2_behavior = BEHAVIOR_REJECT
    h2_threshold = 2 << 16
    h2_warm_up_period_ms = 0
    h2_warm_up_factor = 0
    h2_stat_interval = 1000000
    grpc_controller.table_add(table_name, 'flow_control', [h2_ip],
                              [str(h2_id), str(h2_strategy), str(h2_behavior), str(h2_threshold),
                               str(h2_warm_up_period_ms), str(h2_warm_up_factor), str(h2_stat_interval)])


def circuit_breaking(table_name: str = 'circuit_state_tbl'):
    logging.log(logging.DEBUG, f'table_clear {table_name}')
    grpc_controller.table_clear(table_name)
    h2_ip = topo.get_host_ip('h2')
    h2_id = 1
    h2_retry_timeout = 3000000
    h2_threshold = 200
    h2_recovery_strategy = STRATEGY_DIRECT
    h2_recovery_period = 4000000
    h2_warm_up_rate = 2000
    grpc_controller.table_add(table_name, 'circuit_breaking', [h2_ip],
                              [str(h2_id),
                               str(h2_retry_timeout),
                               str(h2_threshold),
                               str(h2_recovery_strategy),
                               str(h2_recovery_period),
                               str(h2_warm_up_rate)])


class CircuitBreakingHandler(tornado.web.RequestHandler):
    def circuit_breaking(self, resource_id: int) -> bool:
        thrift_controller.register_write('breaker_statue', resource_id, STATE_OPEN)
        thrift_controller.register_write('breaker_will_open', resource_id, int(True))
        statue = thrift_controller.register_read('breaker_statue', resource_id, show=False)
        return True if statue == STATE_OPEN else False

    def post(self):
        resource_id = self.get_body_argument('id', default=None, strip=True)
        self.write('ok' if self.circuit_breaking(int(resource_id)) else 'not ok')
        self.finish()


def make_app():
    return tornado.web.Application((
        (r"/break", CircuitBreakingHandler),
    ))


async def main():
    ip_forwarding()
    flow_control()
    circuit_breaking()

    app = make_app()
    app.listen(11111)
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
