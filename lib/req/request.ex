defmodule Req.Request do
  @moduledoc """
  The request pipeline struct.

  Fields:

    * `:method` - the HTTP request method

    * `:url` - the HTTP request URL

    * `:headers` - the HTTP request headers

    * `:body` - the HTTP request body

    * `:adapter` - a request step that makes the actual HTTP request

    * `:unix_socket` - if set, connect through the given UNIX domain socket

    * `:halted` - whether the request pipeline is halted. See `halt/1`

    * `:request_steps` - the list of request steps

    * `:response_steps` - the list of response steps

    * `:error_steps` - the list of error steps

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.
  """

  defstruct [
    :method,
    :url,
    headers: [],
    body: "",
    adapter: {Req, :run_finch, []},
    unix_socket: nil,
    halted: false,
    request_steps: [],
    response_steps: [],
    error_steps: [],
    private: %{}
  ]

  @doc """
  Sets the request adapter.

  Adapter is a request step that is making the actual HTTP request. It is
  automatically executed as the very last step in the request pipeline.

  The default adapter is using `Finch`.
  """
  def put_adapter(request, adapter) do
    %{request | adapter: adapter}
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(request, key, default \\ nil) when is_atom(key) do
    Map.get(request.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  def put_private(request, key, value) when is_atom(key) do
    put_in(request.private[key], value)
  end

  @doc """
  Halts the request pipeline preventing any further steps from executing.
  """
  def halt(request) do
    %{request | halted: true}
  end

  @doc """
  Builds a request pipeline.

  ## Options

    * `:header` - request headers, defaults to `[]`

    * `:body` - request body, defaults to `""`

    * `:finch` - Finch pool to use, defaults to `Req.Finch` which is automatically started
      by the application. See `Finch` module documentation for more information on starting pools.

    * `:finch_options` - Options passed down to Finch when making the request, defaults to `[]`.
      See `Finch.request/3` for more information.

  """
  def build(method, url, options \\ []) do
    %Req.Request{
      method: method,
      url: URI.parse(url),
      headers: Keyword.get(options, :headers, []),
      body: Keyword.get(options, :body, ""),
      unix_socket: Keyword.get(options, :unix_socket),
      private: %{
        req_finch:
          {Keyword.get(options, :finch, Req.Finch), Keyword.get(options, :finch_options, [])}
      }
    }
  end

  @doc """
  Appends request steps.
  """
  def append_request_steps(request, steps) do
    update_in(request.request_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends request steps.
  """
  def prepend_request_steps(request, steps) do
    update_in(request.request_steps, &(steps ++ &1))
  end

  @doc """
  Appends response steps.
  """
  def append_response_steps(request, steps) do
    update_in(request.response_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends response steps.
  """
  def prepend_response_steps(request, steps) do
    update_in(request.response_steps, &(steps ++ &1))
  end

  @doc """
  Appends error steps.
  """
  def append_error_steps(request, steps) do
    update_in(request.error_steps, &(&1 ++ steps))
  end

  @doc """
  Prepends error steps.
  """
  def prepend_error_steps(request, steps) do
    update_in(request.error_steps, &(steps ++ &1))
  end

  @doc """
  Runs a request pipeline.

  Returns `{:ok, response}` or `{:error, exception}`.
  """
  def run(request) do
    steps = request.request_steps ++ [request.adapter]

    Enum.reduce_while(steps, request, fn step, acc ->
      case run_step(step, acc) do
        %Req.Request{} = request ->
          {:cont, request}

        {%Req.Request{halted: true}, response_or_exception} ->
          {:halt, result(response_or_exception)}

        {request, %Req.Response{} = response} ->
          {:halt, run_response(request, response)}

        {request, %{__exception__: true} = exception} ->
          {:halt, run_error(request, exception)}
      end
    end)
  end

  @doc """
  Runs a request pipeline and returns a response or raises an error.

  See `run/1` for more information.
  """
  def run!(request) do
    case run(request) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run_response(request, response) do
    steps = request.response_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, response}, fn step, {request, response} ->
        case run_step(step, {request, response}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %Req.Response{} = response} ->
            {:cont, {request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, run_error(request, exception)}
        end
      end)

    result(response_or_exception)
  end

  defp run_error(request, exception) do
    steps = request.error_steps

    {_request, response_or_exception} =
      Enum.reduce_while(steps, {request, exception}, fn step, {request, exception} ->
        case run_step(step, {request, exception}) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{__exception__: true} = exception} ->
            {:cont, {request, exception}}

          {request, %Req.Response{} = response} ->
            {:halt, run_response(request, response)}
        end
      end)

    result(response_or_exception)
  end

  @doc false
  def run_step(step, state)

  def run_step({module, function, args}, state) do
    apply(module, function, [state | args])
  end

  def run_step({module, options}, state) do
    apply(module, :run, [state | [options]])
  end

  def run_step(module, state) when is_atom(module) do
    apply(module, :run, [state, []])
  end

  def run_step(func, state) when is_function(func, 1) do
    func.(state)
  end

  defp result(%Req.Response{} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end
end
