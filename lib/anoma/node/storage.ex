defmodule Anoma.Node.Storage do
  @moduledoc """
  I am the Anoma Storage engine, I consist of two parts:
     1. An ordering map which tells of the latest order in the
        qualification map
     2. A qualification map which maps from a qualified key to the stored
        value

  ## Types

    A good way to view this is that for the `t()`, the fields for what
    is stored in mnesia, are simply the order_* and qualified_* values

    type `t Anoma.Node.Storage` to find them all.

    Please also type `t Anoma.Node.Storage.t()` to find out more about the
    central type
  ## API
  The important functions for this API are
     - `setup/1`
     - `ensure_new/1`
     - `get/2`
     - `get/3`
     - `put/3`
     - `put/4`
     - `blocking_read/2`
     - `blocking_read/3`

  For Querying keyspace the following functions are useful
    - `get_keyspace/2`

  If one wants to query the tables by hand then there are manual
  functions, but beware, this is an unintended way of using the API
     - `query_key_space/2`
     - `read_order/2`
     - `read_order_tx/2`
     - `read_at_order/3`
     - `read_at_order_tx/3`
     - `write_at_order/4`
     - `write_at_order_tx/4`


  Please see my testing module `AnomaTest.Storage` to learn more on
  how to use me

  ### Snapshots
  One can snapshot the keys provided in the code by running the following

    - `snapshot_order/1`
    - `put_snapshot/2`
    - `in_snapshot/2`
    - `get_at_snapshot/2`
  """

  alias Anoma.Node.Router
  alias __MODULE__

  use TypedStruct

  require Logger

  @typedoc """
  I represent the qualified and ordered data of storage

  ## Fields
    - `:qualified` - The key value map into storage
    - `:order` - A mapping from keys to the properly qualified keys
  """
  typedstruct do
    field(:qualified, atom(), default: Anoma.Node.Storage.Qualified)
    field(:order, atom(), default: Anoma.Node.Storage.Order)
    field(:rm_commitments, atom(), default: Anoma.Node.Storage.RMCommitments)
    field(:namespace, list(binary()), default: [])
    field(:topic, Router.Addr.t())
  end

  @type result(res) :: {:atomic, res} | {:aborted, any()}

  @typedoc """
  The key we wish to store, also used for order lookup
  """
  @type order_key() :: Noun.t()
  @type order_value() :: list({any(), Noun.t(), non_neg_integer()})

  @typedoc """
  [non_neg_integer(), Noun.t() | non_neg_integer()]
  """
  @type qualified_key() :: nonempty_improper_list(any(), non_neg_integer())
  @type qualified_value() :: any()

  @type snapshot() :: {t(), list({order_key(), non_neg_integer()})}

  def init(%__MODULE__{} = state) do
    {:ok, state}
  end

  def init(opts) do
    return = %Storage{}

    return = %Storage{
      qualified: opts[:qualified] || return.qualified,
      order: opts[:order] || return.order,
      rm_commitments: opts[:rm_commitments] || return.rm_commitments,
      namespace: opts[:namespace] || return.namespace
    }

    # idempotent
    do_setup(return)
    {:ok, return}
  end

  ############################################################
  #                      Public RPC API                      #
  ############################################################

  @spec state(Router.Addr.t()) :: t()
  def state(storage = %Router.Addr{}) do
    Router.call(storage, :state)
  end

  @spec get(Router.Addr.t(), order_key()) ::
          :absent | {:ok, qualified_value()}
  def get(storage = %Router.Addr{}, key) do
    Router.call(storage, {:get, key})
  end

  @spec get_keyspace(Router.Addr.t(), list(any())) ::
          :absent
          | list({qualified_key(), qualified_value()})
          | {:atomic, any()}
  def get_keyspace(storage = %Router.Addr{}, key_space) do
    Router.call(storage, {:get_keyspace, key_space})
  end

  @spec snapshot_order(Router.Addr.t()) :: result(snapshot())
  def snapshot_order(storage = %Router.Addr{}) do
    Router.call(storage, :snapshot_order)
  end

  def read_order_tx(storage = %Router.Addr{}, key) do
    Router.call(storage, {:read_order_tx, key})
  end

  @spec read_at_order_tx(Router.Addr.t(), Noun.t(), non_neg_integer()) ::
          result(list({atom(), qualified_key(), qualified_value()}))
  def read_at_order_tx(storage = %Router.Addr{}, key, order) do
    Router.call(storage, {:read_at_order_tx, key, order})
  end

  @doc """
  I setup storage with the given tables: `t()`.

  I will try to setup all values of storage, even if the first one
  fails due to already being setup, we will try the others.
  """
  @spec remove(Router.Addr.t()) :: :ok | nil
  def remove(storage = %Router.Addr{}) do
    Router.cast(storage, :remove)
  end

  @spec setup(Router.Addr.t()) :: :ok | {:aborted, any()}
  def setup(t = %Router.Addr{}) do
    Router.cast(t, :setup)
  end

  @spec ensure_new(Router.Addr.t()) :: :ok | nil
  def ensure_new(storage = %Router.Addr{}) do
    Router.cast(storage, :ensure_new)
  end

  @spec put(Router.Addr.t(), order_key(), qualified_value()) :: :ok | nil
  def put(storage = %Router.Addr{}, key, value) do
    Router.cast(storage, {:put, key, value})
  end

  @spec delete_key(Router.Addr.t(), order_key()) :: :ok | nil
  def delete_key(storage = %Router.Addr{}, key) do
    Router.cast(storage, {:delete, key})
  end

  @spec write_at_order_tx(
          Router.Addr.t(),
          Noun.t(),
          Noun.t(),
          non_neg_integer()
        ) ::
          :ok | nil
  def write_at_order_tx(storage = %Router.Addr{}, key, value, order) do
    Router.cast(storage, {:write_at_order_tx, key, value, order})
  end

  @spec put_snapshot(Router.addr(), order_key()) :: :ok | nil
  def put_snapshot(storage = %Router.Addr{}, key) do
    Router.cast(storage, {:put_snapshot, key})
  end

  ############################################################
  #                    Genserver Behavior                    #
  ############################################################

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:get, key}, _, storage) do
    {:reply, do_get(storage, key), storage}
  end

  def handle_call({:read_order_tx, key}, _, storage) do
    {:reply, do_read_order_tx(storage, key), storage}
  end

  def handle_call({:get_keyspace, key_space}, _, storage) do
    {:reply, do_get_keyspace(storage, key_space), storage}
  end

  def handle_call({:read_at_order_tx, key, order}, _, storage) do
    {:reply, do_read_at_order_tx(storage, key, order), storage}
  end

  def handle_call(:snapshot_order, _, storage) do
    {:reply, do_snapshot_order(storage), storage}
  end

  def handle_cast(:setup, _, t) do
    do_setup(t)
    {:noreply, t}
  end

  def handle_cast(:remove, _, storage) do
    do_remove(storage)
    {:noreply, storage}
  end

  def handle_cast(:ensure_new, _, storage) do
    do_ensure_new(storage)
    {:noreply, storage}
  end

  def handle_cast({:put_snapshot, key}, _, storage) do
    do_put_snapshot(storage, key)
    {:noreply, storage}
  end

  def handle_cast({:put, key, value}, _, storage) do
    do_put(storage, key, value)
    {:noreply, storage}
  end

  def handle_cast({:delete, key}, _, storage) do
    do_delete_key(storage, key)
    {:noreply, storage}
  end

  def handle_cast({:write_at_order_tx, key, value, order}, _, storage) do
    do_write_at_order_tx(storage, key, value, order)
    {:noreply, storage}
  end

  ############################################################
  #                  Genserver Implementation                #
  ############################################################

  @spec do_ensure_new(t()) :: :ok | {:aborted, any()}
  def do_ensure_new(storage = %__MODULE__{}) do
    # We don't care about errors that can happen here
    do_remove(storage)
    do_setup(storage)
  end

  @spec do_remove(t()) :: :ok | [:ok] | nil
  defp do_remove(storage = %__MODULE__{}) do
    topic = storage.topic
    del_q = :mnesia.delete_table(storage.qualified)
    del_o = :mnesia.delete_table(storage.order)
    del_c = :mnesia.delete_table(storage.rm_commitments)

    unless topic == nil do
      [
        {:delete_qualified, del_q},
        {:delete_ordering, del_o},
        {:delete_commitments, del_c}
      ]
      |> Enum.map(fn x -> Router.cast(topic, x) end)
    end
  end

  @spec do_setup(t()) :: :ok | {:aborted, any()}
  # If this ever gets big, turn it into a map filter situation
  defp do_setup(t = %__MODULE__{}) do
    with {:atomic, :ok} <-
           :mnesia.create_table(t.qualified, attributes: [:key, :value]),
         {:atomic, :ok} <-
           :mnesia.create_table(t.order, attributes: [:key, :order]),
         {:atomic, :ok} <-
           :mnesia.create_table(t.rm_commitments, attributes: [:index, :hash]) do
      CommitmentTree.new(cm_tree_spec(), t.rm_commitments)
    end
  end

  @spec do_get(t(), order_key()) :: :absent | {:ok, qualified_value()}
  defp do_get(storage = %__MODULE__{}, key) do
    with {:atomic, [{_, ^key, order}]} <- do_read_order_tx(storage, key) do
      checked_read_at(storage, key, order)
    else
      _ -> :absent
    end
  end

  @spec do_put_snapshot(t(), order_key()) :: :ok | nil
  def do_put_snapshot(storage = %__MODULE__{}, key) do
    with {:atomic, snapshot} <- do_snapshot_order(storage) do
      do_put(storage, key, snapshot)
    end
  end

  @spec do_delete_key(t(), order_key()) :: :ok | nil
  defp do_delete_key(storage = %__MODULE__{}, key) do
    instrument({:delete_key, key})
    do_put(storage, key, :absent)
  end

  @spec do_put(t(), order_key(), qualified_value()) :: :ok | nil
  defp do_put(storage = %__MODULE__{}, key, value) do
    tx = fn ->
      order = read_order(storage, key)
      new_order = calculate_order(order)
      write_at_order(storage, key, value, new_order)
      instrument({:put_order, new_order})
    end

    topic = storage.topic
    mtx = :mnesia.transaction(tx)
    msg = {:put, key, value} |> Tuple.append(mtx)

    unless topic == nil do
      storage.topic |> Router.cast(msg)
    end
  end

  @spec do_read_order_tx(t(), order_key()) ::
          result(list({atom(), Noun.t(), non_neg_integer()}))
  defp do_read_order_tx(storage = %__MODULE__{}, key) do
    tx = fn -> read_order(storage, key) end
    :mnesia.transaction(tx)
  end

  @spec do_write_at_order_tx(
          t(),
          Noun.t(),
          qualified_value(),
          non_neg_integer()
        ) ::
          :ok
  defp do_write_at_order_tx(storage = %__MODULE__{}, key, value, order) do
    tx = fn -> write_at_order(storage, key, value, order) end
    mtx = :mnesia.transaction(tx)
    msg = {:write, key, value, order} |> Tuple.append(mtx)

    storage.topic |> Router.cast(msg)
  end

  @spec do_get_keyspace(Storage.t(), list(any())) ::
          :absent
          | list({qualified_key(), qualified_value()})
          | {:atomic, any()}
  defp do_get_keyspace(storage = %__MODULE__{}, key_space) do
    with {:atomic, orders} <- read_keyspace_order(storage, key_space) do
      absent_predicate = &(elem(&1, 0) == :absent)

      latest_keys =
        Enum.map(orders, fn [key, order] ->
          checked_read_at_absent_details(storage, key, order)
        end)

      if Enum.any?(latest_keys, absent_predicate) do
        {:absent, key, order} = Enum.find(latest_keys, absent_predicate)
        instrument({:error_missing, key, order})
        :absent
      else
        latest_keys
      end
    end
  end

  @spec do_read_at_order_tx(t(), Noun.t(), non_neg_integer()) ::
          result(list({atom(), qualified_key(), qualified_value()}))
  defp do_read_at_order_tx(storage = %__MODULE__{}, key, order) do
    tx = fn -> read_at_order(storage, key, order) end
    :mnesia.transaction(tx)
  end

  @spec snapshot_order(t()) :: result(snapshot())
  defp do_snapshot_order(storage = %__MODULE__{}) do
    :mnesia.transaction(fn ->
      snapshot = [{{:"$1", :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}]
      {storage, :mnesia.select(storage.order, snapshot)}
    end)
  end

  ############################################################
  #                        Blocking                          #
  ############################################################

  @spec blocking_read(Router.Addr.t(), qualified_key()) ::
          :error | {:ok, any()}
  def blocking_read(storage = %Router.Addr{}, key) do
    do_blocking_read(state(storage), key)
  end

  @spec do_blocking_read(t(), qualified_key()) :: :error | {:ok, any()}
  defp do_blocking_read(storage = %__MODULE__{}, key) do
    instrument({:read, key})

    case key do
      [0 | _] ->
        :error

      [_ | _] ->
        :mnesia.subscribe({:table, storage.qualified, :simple})
        key = namespace_qualified_key(storage, key)
        tx = fn -> :mnesia.read(storage.qualified, key) end
        {:atomic, result} = :mnesia.transaction(tx)

        case result do
          [{_, ^key, value}] ->
            :mnesia.unsubscribe({:table, storage.qualified, :simple})
            {:ok, value}

          [] ->
            receive do
              {:mnesia_table_event, {:write, {_, ^key, value}, _}} ->
                :mnesia.unsubscribe({:table, storage.qualified, :simple})
                {:ok, value}
            end
        end

      _ ->
        :error
    end
  end

  ############################################################
  #                         Snapshots                        #
  ############################################################

  @spec get_at_snapshot(snapshot(), order_key()) ::
          :absent | {:ok, qualified_value()}
  def get_at_snapshot(snapshot = {storage, _}, key) do
    position = in_snapshot(snapshot, key)

    checked_read_at(storage, key, position)
  end

  @spec in_snapshot(snapshot(), order_key()) :: nil | non_neg_integer()
  def in_snapshot({storage, snapshot}, key) do
    List.keyfind(snapshot, namespace_key(storage, key), 0, {nil, nil})
    |> elem(1)
  end

  ############################################################
  #                     Conceptual Helpers                   #
  ############################################################

  # hardcoded cm tree spec for now
  @spec cm_tree_spec() :: CommitmentTree.Spec.t()
  def cm_tree_spec() do
    CommitmentTree.Spec.new(32, 2, 256, fn {x, y} ->
      :crypto.hash(:sha256, x <> y)
    end)
  end

  @spec calculate_order([{any(), any(), number()}]) :: number()
  def calculate_order([{_, _, order}]), do: order + 1
  def calculate_order([]), do: 1

  @spec checked_read_at_absent_details(t(), Noun.t(), non_neg_integer()) ::
          {:absent, Noun.t(), non_neg_integer()}
          | {qualified_key(), qualified_value()}
  defp checked_read_at_absent_details(storage = %__MODULE__{}, key, order) do
    with {:ok, value} <- checked_read_at(storage, key, order) do
      {key, value}
    else
      :absent -> {:absent, key, order}
    end
  end

  @spec checked_read_at(t(), Noun.t(), non_neg_integer()) ::
          :absent | {:ok, qualified_value()}
  defp checked_read_at(storage = %Storage{}, key, order) do
    instrument({:get_order, order})

    with {:atomic, [{_, [^order, ^key | 0], value}]} <-
           do_read_at_order_tx(storage, key, order) do
      case value do
        # the key has been removed
        :absent ->
          :absent

        _ ->
          {:ok, value}
      end
    else
      _ -> :absent
    end
  end

  @spec read_order(t(), order_key()) ::
          list({atom(), Noun.t(), non_neg_integer()})
  def read_order(storage = %__MODULE__{}, key) do
    lst = :mnesia.read(storage.order, namespace_key(storage, key))

    for {at, key, val} <- lst do
      {:ok, key} = denamespace_key(storage, key)
      {at, key, val}
    end
  end

  @spec write_at_order(t(), Noun.t(), qualified_value(), non_neg_integer()) ::
          :ok
  def write_at_order(storage = %__MODULE__{}, key, value, order) do
    :mnesia.write({storage.order, namespace_key(storage, key), order})

    :mnesia.write(
      {storage.qualified,
       namespace_qualified_key(storage, qualified_key(key, order)), value}
    )
  end

  @doc """
  Reads the given keyspace to obtain the latest orders for the keys
  """
  @spec read_keyspace_order(t(), list()) :: result(list(list(any())))
  def read_keyspace_order(storage = %__MODULE__{}, key_query) do
    lst = read_keyspace_at(storage.order, namespace_key(storage, key_query))

    with {:atomic, lst} <- lst do
      lst =
        for [key, value | tl] <- lst do
          {:ok, key} = denamespace_key(storage, key)
          [key, value | tl]
        end

      {:atomic, lst}
    end
  end

  @spec read_at_order(t(), Noun.t(), non_neg_integer()) ::
          list({atom(), qualified_key(), qualified_value()})
  def read_at_order(storage = %__MODULE__{}, key, order) do
    lst =
      :mnesia.read(
        storage.qualified,
        namespace_qualified_key(storage, qualified_key(key, order))
      )

    for {at, key, val} <- lst do
      {:ok, key} = denamespace_qualified_key(storage, key)
      {at, key, val}
    end
  end

  # Add a namespace to a qualified key
  @spec namespace_qualified_key(t(), qualified_key()) :: qualified_key()
  def namespace_qualified_key(storage = %__MODULE__{}, [hd, key | tl]) do
    [hd, namespace_key(storage, key) | tl]
  end

  # Remove the namespace from a qualified key
  @spec denamespace_qualified_key(t(), qualified_key()) ::
          {:ok, qualified_key()} | :error
  def denamespace_qualified_key(storage = %__MODULE__{}, [hd, key | tl]) do
    with {:ok, key} <- denamespace_key(storage, key) do
      {:ok, [hd, key | tl]}
    end
  end

  # Add a namespace to a key
  @spec namespace_key(t(), Noun.t()) :: Noun.t()
  def namespace_key(storage = %__MODULE__{}, key) do
    storage.namespace ++ key
  end

  # Remove the namespace from a key
  @spec denamespace_key(t(), Noun.t()) :: {:ok, Noun.t()} | :error
  def denamespace_key(storage = %__MODULE__{}, key) do
    improper_drop(key, storage.namespace)
  end

  ############################################################
  #                          Helpers                         #
  ############################################################

  # Drop the prefix indicated by the list from the given noun
  @spec improper_drop(Noun.t(), maybe_improper_list()) ::
          {:ok, maybe_improper_list()} | :error
  defp improper_drop(lst, []), do: {:ok, lst}

  defp improper_drop([hd1 | tl1], [hd2 | tl2]) when hd1 == hd2 do
    improper_drop(tl1, tl2)
  end

  defp improper_drop(_, _), do: :error

  @spec qualified_key(Noun.t(), non_neg_integer()) :: qualified_key()
  defp qualified_key(key, order), do: [order, key | 0]

  def check_if_any_absent(latest_keys) do
    absent_predicate = &(elem(&1, 0) == :absent)

    if Enum.any?(latest_keys, absent_predicate) do
      {:absent, key, order} = Enum.find(latest_keys, absent_predicate)
      instrument({:error_missing, key, order})
      :absent
    else
      latest_keys
    end
  end

  @spec read_keyspace_at(any(), list()) :: result(list(list(any())))
  defp read_keyspace_at(table, key_query) do
    keys = create_equality_query(key_query)

    query_tx = fn ->
      :mnesia.select(table, [{{:_, :"$2", :"$3"}, keys, [:"$$"]}])
    end

    instrument({:read_all, key_query})
    :mnesia.transaction(query_tx)
  end

  @spec create_equality_query(list()) :: list()
  defp create_equality_query(keys) do
    keys
    |> Enum.zip(1..length(keys)//1)
    |> Enum.map(fn {key, num} -> create_equality_constraint(key, num) end)
  end

  @spec create_equality_constraint(any(), integer()) ::
          {:==, {:hd, any()}, any()}
  defp create_equality_constraint(key, num) do
    {:==, nth_car(num), key}
  end

  @spec nth_car(integer()) :: {:hd, any()}
  defp nth_car(num) do
    {:hd, 2..num//1 |> Enum.reduce(:"$2", fn _, acc -> {:tl, acc} end)}
  end

  ############################################################
  #                      Instrumentation                     #
  ############################################################

  defp instrument({:get_order, order}) do
    Logger.debug("Getting at order: #{inspect(order)}")
  end

  defp instrument({:put_order, order}) do
    Logger.debug("Putting at order: #{inspect(order)}")
  end

  defp instrument({:read, key}) do
    Logger.info("Regular blocking read at key: #{inspect(key)}")
  end

  defp instrument({:read_all, keys}) do
    Logger.info("Reading key_space at: #{inspect(keys)}")
  end

  defp instrument({:error_missing, key, order}) do
    Logger.error("Missing key: #{inspect(key)} at order: #{inspect(order)}")
  end

  defp instrument({:delete_key, key}) do
    Logger.debug("Deleting key: #{inspect(key)}")
  end
end
