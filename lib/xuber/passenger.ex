defmodule XUber.Passenger do
  use GenStateMachine, restart: :transient

  alias XUber.{
    Grid,
    DispatcherSupervisor
  }

  @search_radius 5
  @search_interval 1000

  def start_link([user, coordinates]) do
    data = %{
      user: user,
      coordinates: coordinates,
      nearby: [],
      request: nil,
      pickup: nil,
      ride: nil,
      driver: nil
    }

    name = String.to_atom(user.name)

    GenStateMachine.start_link(__MODULE__, data, name: name)
  end

  def init(data) do
    PubSub.publish(:passenger, {data.user, :init, data.coordinates})

    Grid.join(self(), data.coordinates, [:passenger])

    :timer.send_interval(@search_interval, :nearby)

    {:ok, :online, data}
  end

  def handle_event({:call, from}, :offline, :online, data) do
    reply = {:reply, from, :ok}

    PubSub.publish(:passenger, {data.user, :offline})

    {:stop_and_reply, :normal, reply, data}
  end

  def handle_event({:call, from}, {:request, source, destination}, :online, data) do
    PubSub.publish(:passenger, {data.user, :request, source, destination})

    {:ok, request} = DispatcherSupervisor.start_child(self(), data.user, source, destination)
    reply = {:reply, from, {:ok, request}}
    new_data = %{data | request: request}

    {:next_state, :requesting, new_data, reply}
  end

  def handle_event({:call, from}, {:dispatched, pickup, driver}, :requesting, data) do
    PubSub.publish(:passenger, {data.user, :dispatched, pickup, driver})

    reply = {:reply, from, {:ok, pickup}}
    new_data = %{data | pickup: pickup, driver: driver, request: nil}

    {:next_state, :waiting, new_data, reply}
  end

  def handle_event({:call, from}, :cancel, :waiting, data) do
    PubSub.publish(:passenger, {data.user, :cancel, data.pickup})

    # TODO: cancel pickup

    reply = {:reply, from, :ok}
    new_data = %{data | pickup: nil}

    {:next_state, :online, new_data, reply}
  end

  def handle_event(
        {:call, from},
        {:depart, ride},
        :waiting,
        data = %{pickup: pickup, driver: driver}
      )
      when not is_nil(driver) and not is_nil(pickup) do
    PubSub.publish(:passenger, {data.user, :depart, ride})

    reply = {:reply, from, :ok}
    new_data = %{data | ride: ride, pickup: nil}

    {:next_state, :riding, new_data, reply}
  end

  def handle_event({:call, from}, :arrive, :riding, data = %{ride: ride}) when not is_nil(ride) do
    PubSub.publish(:passenger, {data.user, :arrive, data.coordinates})

    reply = {:reply, from, :ok}
    new_data = %{data | ride: nil, driver: nil}

    {:next_state, :online, new_data, reply}
  end

  def handle_event({:call, from}, {:move, coordinates}, _state, data) do
    PubSub.publish(:passenger, {data.user, :move, coordinates})
    Grid.update(self(), data.coordinates, coordinates)

    reply = {:reply, from, :ok}
    new_data = %{data | coordinates: coordinates}

    {:keep_state, new_data, reply}
  end

  def handle_event(:info, :nearby, :online, data) do
    PubSub.publish(:passenger, {data.user, :nearby_search, data.coordinates, @search_radius})

    # todo: ensure their are only available drivers
    nearby = Grid.nearby(data.coordinates, @search_radius, [:driver])

    PubSub.publish(:passenger, {data.user, :nearby_results, nearby})

    {:keep_state, %{data | nearby: nearby}}
  end

  def handle_event(:info, :nearby, _other, data) do
    {:keep_state, data}
  end

  def handle_event({:call, from}, :get_user, _any, data) do
    reply = {:reply, from, {:ok, data.user}}

    {:keep_state, data, reply}
  end

  def offline(pid),
    do: GenStateMachine.call(pid, :offline)

  def request(pid, from, to),
    do: GenStateMachine.call(pid, {:request, from, to})

  def cancel(pid),
    do: GenStateMachine.call(pid, :cancel)

  def dispatched(pid, pickup, driver),
    do: GenStateMachine.call(pid, {:dispatched, pickup, driver})

  def depart(pid, ride),
    do: GenStateMachine.call(pid, {:depart, ride})

  def arrive(pid),
    do: GenStateMachine.call(pid, :arrive)

  def move(pid, coordinates),
    do: GenStateMachine.call(pid, {:move, coordinates})

  def get_user(pid),
    do: GenStateMachine.call(pid, :get_user)
end
