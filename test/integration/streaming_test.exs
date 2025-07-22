defmodule StreamingTest do
  use ExUnit.Case
  import BridgeTestHelper
  
  @moduletag :integration
  
  setup do
    channel = start_bridge()
    session_id = create_test_session(channel)
    
    {:ok, channel: channel, session_id: session_id}
  end
  
  describe "variable watching" do
    test "receives initial values", %{channel: channel, session_id: session_id} do
      # Register variables
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel, session_id, "var1", :float, 1.0
      )
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel, session_id, "var2", :integer, 42
      )
      
      # Start watching with initial values
      {:ok, stream} = Snakepit.GRPC.Client.watch_variables(
        channel,
        session_id,
        ["var1", "var2"],
        include_initial: true
      )
      
      # Collect initial values
      test_pid = self()
      
      consumer = Task.async(fn ->
        stream
        |> Enum.take(2)
        |> Enum.each(fn {:ok, update} ->
          send(test_pid, {:initial, update.variable.name, update.variable.value})
        end)
      end)
      
      # Should receive both initial values
      assert_receive {:initial, "var1", 1.0}, 1000
      assert_receive {:initial, "var2", 42}, 1000
      
      Task.await(consumer)
    end
    
    test "receives updates in real-time", %{channel: channel, session_id: session_id} do
      # Register variable
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel, session_id, "watched_var", :float, 0.0
      )
      
      # Start watching
      {:ok, stream} = Snakepit.GRPC.Client.watch_variables(
        channel,
        session_id,
        ["watched_var"],
        include_initial: false
      )
      
      # Start consumer
      test_pid = self()
      
      _consumer = Task.async(fn ->
        Snakepit.GRPC.StreamHandler.consume_stream(stream, fn name, old, new, meta ->
          send(test_pid, {:update, name, old, new})
        end)
      end)
      
      # Wait a bit for stream to establish
      Process.sleep(100)
      
      # Make updates
      for value <- [0.1, 0.2, 0.3] do
        :ok = Snakepit.GRPC.Client.set_variable(
          channel, session_id, "watched_var", value
        )
        
        # Should receive update
        assert_receive {:update, "watched_var", _, ^value}, 1000
      end
    end
    
    test "multiple watchers", %{channel: channel, session_id: session_id} do
      # Register variable
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel, session_id, "multi_watched", :integer, 0
      )
      
      # Start multiple watchers
      watchers = for i <- 1..3 do
        {:ok, stream} = Snakepit.GRPC.Client.watch_variables(
          channel,
          session_id,
          ["multi_watched"],
          include_initial: false
        )
        
        test_pid = self()
        watcher_id = i
        
        Task.async(fn ->
          Snakepit.GRPC.StreamHandler.consume_stream(stream, fn name, _old, new, _meta ->
            send(test_pid, {:watcher_update, watcher_id, name, new})
          end)
        end)
        
        {i, stream}
      end
      
      # Wait for streams to establish
      Process.sleep(200)
      
      # Update variable
      :ok = Snakepit.GRPC.Client.set_variable(
        channel, session_id, "multi_watched", 999
      )
      
      # All watchers should receive the update
      for i <- 1..3 do
        assert_receive {:watcher_update, ^i, "multi_watched", 999}, 2000
      end
    end
    
    test "handles stream disconnection", %{channel: channel, session_id: session_id} do
      # Register variable
      {:ok, _, _} = Snakepit.GRPC.Client.register_variable(
        channel, session_id, "disconnect_test", :string, "initial"
      )
      
      # Start watching
      {:ok, stream} = Snakepit.GRPC.Client.watch_variables(
        channel,
        session_id,
        ["disconnect_test"],
        include_initial: false
      )
      
      # Start consumer that we'll kill
      test_pid = self()
      
      consumer = Task.async(fn ->
        Snakepit.GRPC.StreamHandler.consume_stream(stream, fn name, _old, new, _meta ->
          send(test_pid, {:update, name, new})
        end)
      end)
      
      # Wait for establishment
      Process.sleep(100)
      
      # Kill the consumer
      Task.shutdown(consumer, :brutal_kill)
      
      # Update should not crash anything
      :ok = Snakepit.GRPC.Client.set_variable(
        channel, session_id, "disconnect_test", "updated"
      )
      
      # Should not receive update (consumer is dead)
      refute_receive {:update, _, _}, 500
    end
  end
end