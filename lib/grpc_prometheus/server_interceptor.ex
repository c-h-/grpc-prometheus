defmodule GRPCPrometheus.ServerInterceptor do
  use Prometheus.Metric
  
  require Logger

  @behaviour GRPC.ServerInterceptor

  @labels [:grpc_service, :grpc_method, :grpc_type]
  @labels_with_code [:grpc_code | @labels]

  require Prometheus.Contrib.HTTP

  use Prometheus.Config,
    latency: :histogram,
    histogram_buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000],
    registry: :default

  def setup do
    latency = Config.latency(__MODULE__)
    histogram_buckets = Config.histogram_buckets(__MODULE__)
    registry = Config.registry(__MODULE__)

    Counter.declare(
      name: :grpc_server_started_total,
      labels: @labels,
      help: "Total number of RPCs started on the server.",
      registry: registry
    )

    Counter.declare(
      name: :grpc_server_msg_received_total,
      labels: @labels,
      help: "Total number of RPC stream messages received on the server.",
      registry: registry
    )

    Counter.declare(
      name: :grpc_server_msg_sent_total,
      labels: @labels,
      help: "Total number of gRPC stream messages sent by the server.",
      registry: registry
    )

    Counter.declare(
      name: :grpc_server_handled_total,
      labels: @labels_with_code,
      help: "Total number of RPCs completed on the server, regardless of success or failure.",
      registry: registry
    )

    case latency do
      :histogram ->
        Histogram.declare(
          name: :grpc_server_handled_latency_milliseconds,
          help: "Histogram of response latency of rpcs handled by the server, in milliseconds.",
          labels: @labels_with_code,
          buckets: histogram_buckets,
          registry: registry
        )

      :summary ->
        Summary.declare(
          name: :grpc_server_handled_latency_milliseconds,
          help: "Summary of response latency of rpcs handled by the server, in milliseconds.",
          labels: @labels_with_code,
          registry: registry
        )
      _ ->
        :ok
    end
  end

  def init(opts) do
    opts
  end

  def call(req, %{grpc_type: grpc_type, __interface__: interface} = stream, next, _opts) do
    registry = Config.registry(__MODULE__)
    latency = Config.latency(__MODULE__)
    labels = [stream.service_name, stream.method_name, grpc_type]
    Counter.inc(registry: registry, name: :grpc_server_started_total, labels: labels)

    req =
      if grpc_type == :client_stream || grpc_type == :bidi_stream do
        Stream.map(req, fn r ->
          Counter.inc(registry: registry, name: :grpc_server_msg_received_total, labels: labels)
          r
        end)
      else
        req
      end

    send_reply = fn stream, reply, opts ->
      stream = interface[:send_reply].(stream, reply, opts)
      Counter.inc(registry: registry, name: :grpc_server_msg_sent_total, labels: labels)
      stream
    end

    start = if latency, do: System.monotonic_time()
    result = next.(req, %{stream | __interface__: Map.put(interface, :send_reply, send_reply)})
    stop = if latency, do: System.monotonic_time()

    code =
      case result do
        {:ok, _} ->
          GRPC.Status.code_name(0)

        {:ok, _, _} ->
          GRPC.Status.code_name(0)

        {:error, %GRPC.RPCError{} = error} ->
          GRPC.Status.code_name(error.status)

        {:error, _} ->
          GRPC.Status.code_name(GRPC.Status.unknown())
      end

    labels_with_code = [code | labels]
    Counter.inc(name: :grpc_server_handled_total, labels: labels_with_code)

    case latency do
      :histogram ->
        diff = System.convert_time_unit(stop - start, :native, :millisecond)
        
        Logger.debug("Request latency: #{diff}ms #{inspect(labels_with_code)}")

        Histogram.observe(
          [
            registry: registry,
            name: :grpc_server_handled_latency_milliseconds,
            labels: labels_with_code
          ],
          diff
        )

      :summary ->
        diff = System.convert_time_unit(stop - start, :native, :millisecond)

        Logger.debug("Request latency: #{diff}ms #{inspect(labels_with_code)}")
        
        Summary.observe(
          [
            registry: registry,
            name: :grpc_server_handled_latency_milliseconds,
            labels: labels_with_code
          ],
          diff
        )
      _ ->
        :ok
    end

    result
  end
end
