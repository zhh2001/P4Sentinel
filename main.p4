#define V1MODEL_VERSION 20200408

#include <core.p4>
#include <v1model.p4>

#include "p4src/checksum.p4"
#include "p4src/deparser.p4"
#include "p4src/egress.p4"
#include "p4src/headers.p4"
#include "p4src/ingress.p4"
#include "p4src/parser.p4"

V1Switch(
    p=MyParser(),
    vr=MyVerifyChecksum(),
    ig=MyIngress(),
    eg=MyEgress(),
    ck=MyComputeChecksum(),
    dep=MyDeparser()
) main;
