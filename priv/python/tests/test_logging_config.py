import os
import logging


def test_default_level_is_error():
    os.environ.pop("SNAKEPIT_LOG_LEVEL", None)

    from snakepit_bridge import logging_config

    logging_config.configure_logging(force=True)

    logger = logging_config.get_logger("test")
    assert logger.isEnabledFor(logging.ERROR)
    assert not logger.isEnabledFor(logging.DEBUG)


def test_respects_env_var():
    os.environ["SNAKEPIT_LOG_LEVEL"] = "debug"

    from snakepit_bridge import logging_config

    logging_config.configure_logging(force=True)

    logger = logging_config.get_logger("test")
    assert logger.isEnabledFor(logging.DEBUG)


def test_none_disables_logging():
    os.environ["SNAKEPIT_LOG_LEVEL"] = "none"

    from snakepit_bridge import logging_config

    logging_config.configure_logging(force=True)

    logger = logging_config.get_logger("test")
    assert not logger.isEnabledFor(logging.ERROR)
