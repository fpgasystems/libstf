# Unit tests

The unit tests use the [Coyote unit test framework](../../coyote/sim/unit_test/README.md). Set up the
simulation project as described in the [main README](../../README.md#simulation), then run the
tests from VSCode or from this folder:

```bash
PYTHONPATH=../build-sim:../../coyote/sim python3 -m unittest -v dict_test
```

## Configuration

Tests of designs with a `GlobalConfig` derive from `ConfiguredTestCase`. It discovers the
configuration after the simulation starts and then calls `configure()`, where you write the
configuration and set the inputs and expected outputs. Because the discovery takes a varying amount of
simulation time, these tests run the simulation till it finished instead of for a fixed time:

```python
class MyTest(ConfiguredTestCase):
    def configure(self):
        self.config.get_config(StreamConfig).enqueue_stream_config(0, StreamType.UNSIGNED_INT_32)
        self.set_stream_input(0, ...)
        self.set_expected_output(0, ...)
```

## Performance tests

Performance tests should not use `ConfiguredTestCase`. Inputs sent after the configuration
discovery make the measured cycles jitter by a few cycles. Instead, write the registers directly
before the simulation starts:

```python
self.write_register(register(3, StreamConfig.register_value(StreamType.UNSIGNED_INT_32)))
```
