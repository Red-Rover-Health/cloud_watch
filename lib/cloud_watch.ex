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
    state = configure(name, [])
    timer_ref = Process.send_after(self(), :flush, state.max_timeout)
    {:ok, {timer_ref, state}}
  end

  def init(_), do: init({__MODULE__, __MODULE__})

  def handle_call({:configure, opts}, {timer_ref, %{name: name}}) do
    {:ok, :ok, {timer_ref, configure(name, opts)}}
  end

  def handle_call(_, state) do
    {:ok, :ok, state}
  end

  def handle_event(
        {level, _gl, {Logger, msg, ts, md}},
        {timer_ref, %{level: min_level, metadata_filter: metadata_filter} = state}
      ) do
    if Logger.compare_levels(level, min_level) != :lt and metadata_matches?(md, metadata_filter) do
      {:ok, new_state} =
        state
        |> add_message(level, msg, ts, md)
        |> flush()

      {:ok, {timer_ref, new_state}}
    else
      {:ok, {timer_ref, state}}
    end
  end

  def handle_event(:flush, {timer_ref, state}) do
    {:ok, {timer_ref, purge_buffer(state)}}
  end

  def handle_info(:flush, {timer_ref, state}) do
    {:ok, flushed_state} = flush(state, force: true)
    Process.cancel_timer(timer_ref)
    timer_ref = Process.send_after(self(), :flush, state.max_timeout)
    {:ok, {timer_ref, flushed_state}}
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

  defp configure(name, opts) do
    env = Application.get_env(:logger, name, [])
    opts = Keyword.merge(env, opts)
    Application.put_env(:logger, name, opts)

    level = Keyword.get(opts, :level, @default_level)
    format_opts = Keyword.get(opts, :format, @default_format)
    format = Logger.Formatter.compile(format_opts)
    metadata = Keyword.get(opts, :metadata, [])
    metadata_filter = Keyword.get(opts, :metadata_filter)

    log_group_name = Keyword.get(opts, :log_group_name)
    log_stream_name = Keyword.get(opts, :log_stream_name)
    max_buffer_size = Keyword.get(opts, :max_buffer_size, @default_max_buffer_size)
    max_timeout = Keyword.get(opts, :max_timeout, @default_max_timeout)

    # AWS configuration, only if needed by the AWS library
    region = Keyword.get(opts, :region)
    access_key_id = Keyword.get(opts, :access_key_id)
    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)
    secret_access_key = Keyword.get(opts, :secret_access_key)
    client = AwsProxy.client(access_key_id, secret_access_key, region, endpoint)

    %{
      name: name,
      format: format,
      level: level,
      metadata: metadata,
      metadata_filter: metadata_filter,
      buffer: [],
      # for a large list, this is less expensive than length(buffer)
      buffer_length: 0,
      buffer_size: 0,
      client: client,
      log_group_name: log_group_name,
      log_stream_name: log_stream_name,
      max_buffer_size: max_buffer_size,
      max_timeout: max_timeout,
      sequence_token: nil,
      flushed_at: nil
    }
  end

  defp purge_buffer(state) do
    %{state | buffer: [], buffer_length: 0, buffer_size: 0}
  end

  defp add_message(
         %{buffer: buffer, buffer_length: buffer_length, buffer_size: buffer_size} = state,
         level,
         msg,
         ts,
         md
       ) do
    message =
      level
      |> format_event(msg, ts, md, state)
      |> IO.chardata_to_string()

    # buffer order is not relevant, we'll reverse or sort later if needed
    buffer = [{%{message: message, timestamp: Utils.convert_timestamp(ts)}, md} | buffer]

    %{
      state
      | buffer: buffer,
        buffer_length: buffer_length + 1,
        buffer_size: buffer_size + byte_size(message) + 26
    }
  end

  @doc false
  @spec metadata_matches?(Keyword.t(), nil | Keyword.t() | mfa()) :: true | false
  def metadata_matches?(_md, nil), do: true

  def metadata_matches?(md, {module, function_name, args}), do: apply(module, function_name, [args | md])

  def metadata_matches?(_md, []), do: true

  def metadata_matches?(md, [{key, val} | rest]) do
    case Keyword.fetch(md, key) do
      {:ok, ^val} -> metadata_matches?(md, rest)
      _ -> false
    end
  end

  defp take_metadata(metadata, :all), do: metadata

  defp take_metadata(metadata, keys), do: Keyword.take(metadata, keys)

  defp format_event(level, msg, ts, md, %{format: format, metadata: keys}) do
    Logger.Formatter.format(format, level, msg, ts, take_metadata(md, keys))
  end

  defp flush(_state, _opts \\ [force: false])

  defp flush(
         %{
           buffer_length: buffer_length,
           buffer_size: buffer_size,
           max_buffer_size: max_buffer_size
         } = state,
         force: false
       )
       when buffer_size < max_buffer_size and buffer_length < @max_buffer_size do
    {:ok, state}
  end

  defp flush(%{buffer: []} = state, _opts), do: {:ok, state}

  defp flush(%{buffer: buffer} = state, opts) do
    log_stream_name = resolve_name(state.log_stream_name)

    buffer
    |> Enum.group_by(
      fn {_event, metadata} -> resolve_name(state.log_group_name, metadata) end,
      fn {event, _metadata} -> event end
    )
    |> Enum.reduce({:ok, %{state | buffer: []}}, fn
      {log_group_name, buffer}, {:ok, state} ->
        do_flush(%{state | buffer: buffer}, opts, log_group_name, log_stream_name)

      _, error ->
        error
    end)
  end

  defp do_flush(%{buffer: _buffer} = state, _opts, nil, _log_stream_name) do
    {:ok, state |> purge_buffer()}
  end

  defp do_flush(%{buffer: buffer} = state, opts, log_group_name, log_stream_name) do
    events = %{
      logEvents:
        buffer
        |> Enum.sort_by(& &1.timestamp)
        |> Enum.map(fn
          %{message: message} = event ->
            if String.length(message) > 262_144 do
              # (1024 * 256) - `{"timestamp":"yyyy-mm-ddThh:mm:ss","message":""}`.length
              %{event | message: String.slice(message, 0..262_096)}
            else
              event
            end

          event ->
            event
        end),
      logGroupName: log_group_name,
      logStreamName: log_stream_name,
      sequenceToken: state.sequence_token
    }

    case AwsProxy.put_log_events(state.client, events) do
      {:ok, %{"nextSequenceToken" => next_sequence_token}, _} ->
        {:ok, state |> purge_buffer() |> Map.put(:sequence_token, next_sequence_token)}

      {:error, {type, _message, next_sequence_token}}
      when type in ["DataAlreadyAcceptedException", "InvalidSequenceTokenException"] ->
        state
        |> Map.put(:sequence_token, next_sequence_token)
        |> do_flush(opts, log_group_name, log_stream_name)

      {:error,
       {"DataAlreadyAcceptedException",
        "The given batch of log events has already been accepted. The next batch can be sent with sequenceToken: " <>
            next_sequence_token}} ->
        state
        |> Map.put(:sequence_token, next_sequence_token)
        |> do_flush(opts, log_group_name, log_stream_name)

      {:error,
       {"InvalidSequenceTokenException",
        "The given sequenceToken is invalid. The next expected sequenceToken is: " <> next_sequence_token}} ->
        state
        |> Map.put(:sequence_token, next_sequence_token)
        |> do_flush(opts, log_group_name, log_stream_name)

      {:error, {"ResourceNotFoundException", "The specified log group does not exist."}} ->
        {:ok, _, _} = AwsProxy.create_log_group(state.client, %{logGroupName: log_group_name})

        {:ok, _, _} =
          AwsProxy.create_log_stream(
            state.client,
            %{logGroupName: log_group_name, logStreamName: log_stream_name}
          )

        state
        |> Map.put(:sequence_token, nil)
        |> do_flush(opts, log_group_name, log_stream_name)

      {:error, {"ResourceNotFoundException", "The specified log stream does not exist."}} ->
        {:ok, _, _} =
          AwsProxy.create_log_stream(
            state.client,
            %{logGroupName: log_group_name, logStreamName: log_stream_name}
          )

        state
        |> Map.put(:sequence_token, nil)
        |> do_flush(opts, log_group_name, log_stream_name)

      {:error, {"ThrottlingException", "Rate exceeded"}} ->
        do_flush(state, opts, log_group_name, log_stream_name)

      {:error, %HTTPoison.Error{id: nil, reason: reason}}
      when reason in [:closed, :connect_timeout, :timeout] ->
        do_flush(state, opts, log_group_name, log_stream_name)

      {:error, {type, _message}} when type in [:closed, :connect_timeout, :timeout] ->
        do_flush(state, opts, log_group_name, log_stream_name)
    end
  end

  # Apply a MFA tuple (Module, Function, Attributes) to obtain the name. Function must return a string
  defp resolve_name({m, f, a}, metadata) do
    :erlang.apply(m, f, [metadata | a])
  end

  # Use the name directly
  defp resolve_name(name, _metadata) do
    name
  end

  # Apply a MFA tuple (Module, Function, Attributes) to obtain the name. Function must return a string
  defp resolve_name({m, f, a}) do
    :erlang.apply(m, f, a)
  end

  # Use the name directly
  defp resolve_name(name) do
    name
  end
end
