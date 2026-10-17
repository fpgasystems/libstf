
interface stream_profile_i
    import libstf::*;
;
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
