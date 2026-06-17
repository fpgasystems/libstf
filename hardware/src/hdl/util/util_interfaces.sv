import libstf::*;

interface stream_profile_i;
    stream_profile_t counters;
    logic            stop;

    modport m (
        input  stop,
        output counters
    );

    modport s (
        input  counters,
        output stop
    );
endinterface
