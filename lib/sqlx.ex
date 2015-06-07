defmodule Sqlx do
	use Application
	use Silverb, 	[
						{"@pools", :application.get_env(:sqlx, :pools, nil)},
						{"@ttl", :application.get_env(:sqlx, :timeout, nil)}
					]
	require Record
	Record.defrecord :result_packet, Record.extract(:result_packet, from_lib: "emysql/include/emysql.hrl")
	Record.defrecord :field, Record.extract(:field, from_lib: "emysql/include/emysql.hrl")
	Record.defrecord :ok_packet, Record.extract(:ok_packet, from_lib: "emysql/include/emysql.hrl")
	Record.defrecord :error_packet, Record.extract(:error_packet, from_lib: "emysql/include/emysql.hrl")


  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    :application.set_env(:emysql, :default_timeout, @ttl)
    Enum.each(@pools, fn({name, settings}) -> :ok = :emysql.add_pool(name, settings) end)


    children = [
      # Define workers and child supervisors to be supervised
      # worker(Sqlx.Worker, [arg1, arg2, arg3])
    ]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sqlx.Supervisor]
    Supervisor.start_link(children, opts)
  end



	def prepare_query(str, args) do
		%{resstr: resstr, args: []} = String.codepoints(str) 
		|> Enum.reduce(%{resstr: "", args: args}, 
			fn 
			"?", %{resstr: resstr, args: [arg|rest]} -> %{resstr: resstr<>prepare_query_proc(arg), args: rest}
			some, %{resstr: resstr, args: args} -> %{resstr: resstr<>some, args: args}
			end)
		resstr
	end
	defp prepare_query_proc(bin) when is_binary(bin), do: "'"<>String.replace(bin, "'", "\\'")<>"'"
	defp prepare_query_proc(int) when is_integer(int), do: to_string(int)
	defp prepare_query_proc(flo) when is_float(flo), do: Float.to_string(flo, [decimals: 10, compact: true]) 
	defp prepare_query_proc(lst) when is_list(lst) do
		Enum.map(lst, &prepare_query_proc/1)
		|> List.flatten
		|> Enum.join(",")
	end
	defp prepare_query_proc(nil), do: "NULL"
	defp prepare_query_proc(:undefined), do: "NULL"



	def exec(query, args, pool \\ :mysql) do
		case :emysql.execute(pool, prepare_query(query, args)) do
			result_packet(rows: rows, field_list: field_list) -> 
				Enum.map(field_list, fn(field(name: name)) -> String.to_atom(name) end)
				|> parse_select(rows)
			some -> [some] |> List.flatten |> check_transaction
		end
	end
	defp parse_select(headers, rows) do
		Enum.map(rows, 
			fn(this_row) -> 
				Stream.zip(headers, this_row)
				|> Enum.reduce(%{}, 
					fn
					{k,:undefined}, resmap -> Map.put(resmap, k, nil)
					{k,v}, resmap -> Map.put(resmap, k, v)
					end)
			end)
	end
	defp check_transaction(lst) do
		Enum.reduce(lst, %{ok: [], error: []}, 
			fn
			el = ok_packet(), resmap -> Map.update!(resmap, :ok, &([el|&1]))
			el = error_packet(), resmap -> Map.update!(resmap, :error, &([el|&1]))
			end)
	end



	def insert(lst = [_|_], keys = [_|_], tab, pool \\ :mysql), do: insert_proc("", lst, keys, tab, pool)
	def insert_ignore(lst = [_|_], keys = [_|_], tab, pool \\ :mysql), do: insert_proc("IGNORE", lst, keys, tab, pool)
	defp insert_proc(mod, lst, keys, tab, pool) do
		"""
		INSERT #{mod} INTO #{tab} 
		(#{Enum.join(keys, ",")}) 
		VALUES 
		#{Stream.map(lst, fn(_) -> "(?)" end) |> Enum.join(",")};
		"""
		|> exec(Enum.map(lst, &(make_args(&1, keys))), pool)
	end
	def insert_duplicate(lst = [_|_], keys = [_|_], uniq_keys, tab, pool \\ :mysql) when is_list(uniq_keys) do
		case 	Stream.filter_map(keys, &(not(Enum.member?(uniq_keys,&1))), &("#{&1} = VALUES(#{&1})"))
				|> Enum.join(",") do
			"" -> raise("#{__MODULE__} : no any duplication part of query.. keys #{inspect keys}..  uniq_keys #{inspect uniq_keys}")
			dupl -> 
				"""
				INSERT INTO #{tab} 
				(#{Enum.join(keys, ",")}) 
				VALUES 
				#{Stream.map(lst, fn(_) -> "(?)" end) |> Enum.join(",")} 
				ON DUPLICATE KEY UPDATE 
				#{dupl};
				"""
				|> exec(Enum.map(lst, &(make_args(&1, keys))), pool)
		end
	end
	defp make_args(map, keys) do
		Enum.map(keys, 
			fn(k) ->
				case Map.has_key?(map, k) do
					true -> Map.get(map, k)
					false -> raise("#{__MODULE__} : no key #{inspect k} in struct #{inspect map}")
				end
			end)
	end

end
