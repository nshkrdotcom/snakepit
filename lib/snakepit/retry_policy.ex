defmodule Snakepit.RetryPolicy do
  @moduledoc """
  Retry policy with exponential backoff.

  Configures retry behavior including max attempts, backoff timing,
  and which errors are retriable.

  ## Usage

      policy = RetryPolicy.new(
        max_attempts: 3,
        backoff_ms: [100, 200, 400],
        jitter: true
      )

      if RetryPolicy.should_retry?(policy, attempt) do
        delay = RetryPolicy.backoff_for_attempt(policy, attempt)
        Process.sleep(delay)
        # retry...
      end
  """

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff_ms: [non_neg_integer()],
          base_backoff_ms: non_neg_integer(),
          backoff_multiplier: float(),
          max_backoff_ms: non_neg_integer(),
          jitter: boolean(),
          jitter_factor: float(),
          retriable_errors: [atom()] | :all
        }

  # Note: These struct defaults are compile-time constants.
  # Runtime configurable defaults are handled in new/1 via Snakepit.Defaults
  defstruct max_attempts: 3,
            backoff_ms: [100, 200, 400, 800, 1600],
            base_backoff_ms: 100,
            backoff_multiplier: 2.0,
            max_backoff_ms: 30_000,
            jitter: false,
            jitter_factor: 0.25,
            retriable_errors: [:timeout, :unavailable, :connection_refused, :worker_crash]

  alias Snakepit.Defaults

  @doc """
  Creates a new retry policy.

  ## Options

  - `:max_attempts` - Maximum retry attempts (default: 3)
  - `:backoff_ms` - List of backoff delays in ms (default: [100, 200, 400, 800, 1600])
  - `:base_backoff_ms` - Base for exponential backoff (default: 100)
  - `:backoff_multiplier` - Multiplier for exponential backoff (default: 2.0)
  - `:max_backoff_ms` - Maximum backoff delay (default: 30000)
  - `:jitter` - Add random jitter to delays (default: false)
  - `:jitter_factor` - Jitter range as fraction of delay (default: 0.25)
  - `:retriable_errors` - List of error atoms to retry, or :all (default: common errors)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    # Use runtime-configurable defaults, then apply any user-provided options
    defaults = [
      max_attempts: Defaults.retry_max_attempts(),
      backoff_ms: Defaults.retry_backoff_sequence(),
      base_backoff_ms: Defaults.retry_base_backoff_ms(),
      backoff_multiplier: Defaults.retry_backoff_multiplier(),
      max_backoff_ms: Defaults.retry_max_backoff_ms(),
      jitter_factor: Defaults.retry_jitter_factor()
    ]

    merged = Keyword.merge(defaults, opts)
    struct(__MODULE__, merged)
  end

  @doc """
  Checks if another retry attempt should be made.
  """
  @spec should_retry?(t(), non_neg_integer()) :: boolean()
  def should_retry?(%__MODULE__{max_attempts: max}, attempt) do
    attempt < max
  end

  @doc """
  Checks if an error is retriable according to the policy.
  """
  @spec retry_for_error?(t(), {:error, atom()} | term()) :: boolean()
  def retry_for_error?(%__MODULE__{retriable_errors: :all}, _error), do: true

  def retry_for_error?(%__MODULE__{retriable_errors: errors}, {:error, reason})
      when is_atom(reason) do
    reason in errors
  end

  def retry_for_error?(_policy, _error), do: false

  @doc """
  Returns the backoff delay for a given attempt.
  """
  @spec backoff_for_attempt(t(), pos_integer()) :: non_neg_integer()
  def backoff_for_attempt(%__MODULE__{} = policy, attempt) do
    base_delay =
      case Enum.at(policy.backoff_ms, attempt - 1) do
        nil -> List.last(policy.backoff_ms) || policy.base_backoff_ms
        delay -> delay
      end

    # Apply max cap
    delay = min(base_delay, policy.max_backoff_ms)

    # Apply jitter if enabled
    if policy.jitter do
      apply_jitter(delay, policy.jitter_factor)
    else
      delay
    end
  end

  # Private functions

  defp apply_jitter(delay, factor) do
    jitter_range = trunc(delay * factor)
    jitter = :rand.uniform(jitter_range * 2 + 1) - jitter_range - 1
    max(0, delay + jitter)
  end
end
