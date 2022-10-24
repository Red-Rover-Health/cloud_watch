defmodule CloudWatch do
  @behaviour :gen_event
  @default_endpoint "amazonaws.com"
  @default_format "$metadata[$level] $message\n"
  @default_level :info
  @default_max_buffer_size 10_485
  @default_max_timeout 60_000
  @max_buffer_size 10_000

  alias CloudWatch.Utils
  alias CloudWatch.AwsProxy

  def init({__MODULE__, name}) do
    {:ok, %{}}
  end

  def init(_), do: init({__MODULE__, __MODULE__})

  def handle_call({:configure, opts}, %{name: name}) do
    {:ok, :ok, %{}}
  end

  def handle_call(_, state) do
    {:ok, :ok, state}
  end

  def handle_event(event, state) do
    {:ok, state}
  end

  def handle_event(:flush, state) do
    {:ok, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  def code_change(_previous_version_number, state, _extra) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end
end
