import os
import warnings

from p4utils.mininetlib.network_API import NetworkAPI

warnings.filterwarnings('ignore', category=DeprecationWarning)
warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings('ignore', category=SyntaxWarning)


def main():
    net = NetworkAPI()

    net.setCompiler(p4rt=True)

    sw = net.addP4RuntimeSwitch('sw')

    net.setP4Source(sw, './main.p4')
    net.setP4CliInput(sw, './commands/sw.sh')

    net.setP4SwitchId(sw, 1)
    net.setGrpcPort(sw, 50001)
    net.setThriftPort(sw, 10001)

    h1 = net.addHost('h1')
    h2 = net.addHost('h2')
    net.addLink(sw, h1)
    net.addLink(sw, h2)

    net.mixed()

    net.setIntfPort(h1, sw, 0)
    net.setIntfPort(h2, sw, 0)
    net.setIntfPort(sw, h1, 1)
    net.setIntfPort(sw, h2, 2)

    net.setIntfMac(h1, sw, '00:00:0a:00:00:01')
    net.setIntfMac(h2, sw, '00:00:0a:00:00:02')
    net.setIntfMac(sw, h1, '00:01:0a:00:00:01')
    net.setIntfMac(sw, h2, '00:01:0a:00:00:02')

    net.setIntfIp(h1, sw, '10.0.0.1/24')
    net.setIntfIp(h2, sw, '10.0.0.2/24')

    net.setTopologyFile('./topology.json')
    net.setLogLevel('info')

    os.makedirs('./log', mode=0o777, exist_ok=True)
    os.makedirs('./pcap', mode=0o777, exist_ok=True)

    net.enableLogAll()
    net.enableLog(sw, './log')

    net.enablePcapDumpAll()
    net.enablePcapDump(sw, './pcap')

    net.enableCli()
    net.startNetwork()


if __name__ == '__main__':
    main()
