defmodule Snakepit.Test.FakeDoctor do
  @moduledoc """
  Test double for Snakepit.EnvDoctor.
  """

  @key {:snakepit, __MODULE__}

  def configure(opts) do
    :persistent_term.put(@key, opts)
  end

  def reset do
    :persistent_term.put(@key, %{})
  end

  def ensure_python! do
    opts = :persistent_term.get(@key, %{})

    if pid = opts[:pid] do
      send(pid, {:env_doctor_called, self()})
    end

    case opts[:action] do
      {:raise, reason} -> raise RuntimeError, reason
      {:raise, reason, kind} -> raise(kind, reason)
      _ -> :ok
    end
  end
end
