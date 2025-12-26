defmodule Snakepit.RuntimeContractIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias Snakepit.GRPC.ClientImpl

  test "accepts kwargs and call_type payloads" do
    payload = %{
      library: "numpy",
      python_module: "numpy",
      function: "mean",
      args: [1, 2, 3],
      kwargs: %{axis: 0},
      call_type: "function",
      idempotent: true,
      payload_version: 1
    }

    assert {:ok, request, _opts} =
             ClientImpl.prepare_execute_tool_request(
               "session-contract",
               "snakebridge.call",
               payload,
               %{}
             )

    kwargs_any = request.parameters["kwargs"]
    assert Jason.decode!(kwargs_any.value) == %{"axis" => 0}

    call_type_any = request.parameters["call_type"]
    assert Jason.decode!(call_type_any.value) == "function"

    idempotent_any = request.parameters["idempotent"]
    assert Jason.decode!(idempotent_any.value) == true

    args_any = request.parameters["args"]
    assert Jason.decode!(args_any.value) == [1, 2, 3]
  end
end
