# Copyright 2021 Splunk Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
defmodule Schema.Cache do
  @moduledoc """
  This module keeps the schema in memory, aka schema cache.
  """

  alias Schema.Utils

  require Logger

  @enforce_keys [:version, :dictionary, :categories, :common, :classes, :objects]
  defstruct ~w[version dictionary common categories classes objects]a

  @spec new(map()) :: __MODULE__.t()
  def new(version) do
    %__MODULE__{
      version: version,
      dictionary: Map.new(),
      categories: Map.new(),
      common: Map.new(),
      classes: Map.new(),
      objects: Map.new()
    }
  end

  @type t() :: %__MODULE__{}
  @type class_t() :: map()
  @type object_t() :: map()
  @type category_t() :: map()
  @type dictionary_t() :: map()

  # The schema JSON file extension.
  @schema_file ".json"

  # The default location of the schema files.
  @data_dir "../schema"
  @ext_dir "extensions"

  # to include event traits
  @include :"$include"

  @version_file "version.json"

  @categories_file "categories.json"
  @dictionary_file "dictionary.json"

  @events_dir "events"
  @objects_dir "objects"

  @doc """
  Load the schema files and initialize the cache.
  """
  @spec init :: __MODULE__.t()
  def init() do
    home = data_dir()

    Logger.info(fn -> "#{inspect(__MODULE__)}: loading schema: #{home}" end)

    version = read_version(home)
    Logger.info(fn -> "#{inspect(__MODULE__)}: schema version: #{inspect(version)}" end)

    categories = read_categories(home)
    dictionary = read_dictionary(home)
    {common, classes} = read_classes(home, categories.attributes)
    objects = read_objects(home)

    dictionary = Utils.update_dictionary(dictionary, common, classes, objects)
    objects = Utils.update_objects(dictionary, objects)

    new(version)
    |> set_categories(categories)
    |> set_dictionary(dictionary)
    |> set_common(common)
    |> set_classes(classes)
    |> set_objects(objects)
  end

  @spec to_uid(nil | binary) :: atom
  def to_uid(nil), do: nil

  def to_uid(name) do
    name
    |> String.downcase()
    |> String.to_atom()
  end

  @spec version(__MODULE__.t()) :: String.t()
  def version(%__MODULE__{version: version}), do: version[:version]

  @spec dictionary(__MODULE__.t()) :: dictionary_t()
  def dictionary(%__MODULE__{dictionary: dictionary}), do: dictionary

  @spec categories(__MODULE__.t()) :: map()
  def categories(%__MODULE__{categories: categories}), do: categories

  @spec categories(__MODULE__.t(), any) :: nil | category_t()
  def categories(%__MODULE__{categories: categories, classes: classes}, id) do
    case Map.get(categories.attributes, id) do
      nil ->
        nil

      category ->
        add_classes({id, category}, classes)
    end
  end

  @spec classes(__MODULE__.t()) :: list
  def classes(%__MODULE__{classes: classes}), do: classes

  @spec classes(__MODULE__.t(), atom()) :: nil | class_t()
  def classes(%__MODULE__{dictionary: dictionary, common: common}, :base_event) do
    enrich(common, dictionary.attributes)
  end

  def classes(%__MODULE__{dictionary: dictionary, classes: classes}, id) do
    case Map.get(classes, id) do
      nil ->
        nil

      class ->
        enrich(class, dictionary.attributes)
    end
  end

  def find_class(%__MODULE__{dictionary: dictionary, classes: classes}, uid) do
    case Enum.find(classes, fn {_, class} -> class[:uid] == uid end) do
      {_, class} -> enrich(class, dictionary.attributes)
      nil -> nil
    end
  end

  @spec objects(__MODULE__.t()) :: map()
  def objects(%__MODULE__{objects: objects}), do: objects

  @spec objects(__MODULE__.t(), any) :: nil | object_t()
  def objects(%__MODULE__{dictionary: dictionary, objects: objects}, id) do
    case Map.get(objects, id) do
      nil ->
        nil

      object ->
        enrich(object, dictionary.attributes)
    end
  end

  defp add_classes({id, category}, classes) do
    category_id = Atom.to_string(id)

    list =
      Enum.filter(
        classes,
        fn {_name, class} ->
          Map.get(class, :category) == category_id
        end
      )

    Map.put(category, :classes, list)
  end

  defp enrich(map, dictionary) do
    attributes =
      Enum.map(
        map.attributes,
        fn {name, attribute} ->
          case dictionary[name] do
            nil ->
              Logger.warn("undefined attribute: #{name}")
              {name, attribute}

            base ->
              {name, Utils.deep_merge(base, attribute)}
          end
        end
      )

    Map.put(map, :attributes, attributes)
  end

  # The location of the schema files.
  @spec data_dir :: String.t()
  def data_dir() do
    Application.get_env(:schema_server, __MODULE__)
    |> Keyword.get(:home) ||
      @data_dir
  end

  @spec read_version(binary) :: any
  def read_version(home) do
    file = Path.join(home, @version_file)

    if File.regular?(file) do
      read_json_file(file)
    else
      Logger.warn("version file #{file} not found")
      "0.0.0"
    end
  end

  @spec read_categories(binary) :: any
  def read_categories(home) do
    Path.join(home, @categories_file)
    |> read_json_file
    |> read_json_files(Path.join(home, @ext_dir), @categories_file)
  end

  @spec read_dictionary(binary) :: any
  def read_dictionary(home) do
    Path.join(home, @dictionary_file)
    |> read_json_file
    |> read_json_files(Path.join(home, @ext_dir), @dictionary_file)
  end

  @spec read_classes(binary, map) :: {map, map}
  def read_classes(home, categories) do
    {base, classes} = read_classes(home)

    classes =
      classes
      |> Stream.map(fn {name, map} -> {name, resolve_extends(name, classes, map)} end)
        # remove intermediate classes
      |> Stream.filter(fn {_name, class} -> Map.has_key?(class, :uid) end)
      |> Stream.map(fn class -> enrich_class(class, categories) end)
      |> Enum.to_list()
      |> Map.new()

    {base, classes}
  end

  @spec read_classes(binary) :: {map, map}
  def read_classes(home) do
    classes =
      Map.new()
      |> read_schema_files(Path.join(home, @events_dir))
      |> read_schema_files(Path.join(home, @ext_dir), @events_dir)
      |> update_see_also()
      |> resolve_includes(home)
      |> Enum.map(fn class -> attribute_source(home, class) end)
      |> Map.new()

    {Map.get(classes, :base_event), classes}
  end

  @spec read_objects(binary) :: map
  def read_objects(home) do
    Map.new()
    |> read_schema_files(Path.join(home, @objects_dir))
    |> read_schema_files(Path.join(home, @ext_dir), @objects_dir)
    |> resolve_extends()
    |> Enum.filter(
         fn {key, _object} ->
           # removes abstract objects
           !String.starts_with?(Atom.to_string(key), "_")
         end
       )
    |> Map.new()
  end

  defp read_json_files(map, path, name) do
    if File.dir?(path) do
      case File.ls(path) do
        {:ok, files} ->
          files
          |> Stream.map(fn file -> Path.join(path, file) end)
          |> Enum.reduce(map, fn file, m -> read_json_files(m, file, name) end)

        error ->
          Logger.warn("unable to access #{path} directory. Error: #{inspect(error)}")
          raise error
      end
    else
      if Path.basename(path) == name do
        Logger.info("reading extension: #{path}")

        read_json_file(path)
        |> Utils.deep_merge(map)
      else
        map
      end
    end
  end

  # Add attributes from the included traits
  defp resolve_includes(classes, home) do
    Enum.map(
      classes,
      fn {name, data} ->
        {name, include_attributes(data, home)}
      end
    )
  end

  defp include(data, home) do
    case Map.get(data, @include) do
      nil ->
        data

      include ->
        include_json_file(Map.delete(data, @include), include, home)
    end
  end

  defp include_attributes(data, home) do
    case Map.get(data.attributes, @include) do
      nil ->
        data

      include when is_binary(include) ->
        include_file(data, include, home)

      include when is_list(include) ->
        Enum.reduce(include, data, fn file, acc -> include_file(acc, file, home) end)
    end
  end

  defp include_file(data, file, home) do
    path = Path.join(home, file)
    Logger.info("#{data[:type]} includes: #{path}")

    included = read_json_file(path)
    attributes = Utils.deep_merge(included.attributes, Map.delete(data.attributes, @include))

    Map.put(data, :attributes, attributes)
  end

  defp include_json_file(data, file, home) do
    path = Path.join(home, file)

    Logger.info("#{data[:type]} includes: #{path}")

    read_json_file(path)
    |> Utils.deep_merge(data)
  end

  # Add category_id, class_id, and event_uid
  defp enrich_class({name, class}, categories) do
    data =
      class
      |> add_event_uid(name)
      |> add_class_id(name)
      |> add_category_id(name, categories)

    {name, data}
  end

  defp add_event_uid(data, name) do
    Map.update!(
      data,
      :attributes,
      fn attributes ->
        id = attributes[:disposition_id] || %{}
        uid = attributes[:event_uid] || %{}
        class_id = (data[:uid] || 0) * 1000
        caption = data[:name] || "UNKNOWN"

        enum =
          case id[:enum] do
            nil ->
              %{"0" => "UNKNOWN"}

            values ->
              for {key, val} <- values, into: %{} do
                {
                  make_event_uid(class_id, key),
                  Map.put(val, :name, make_event_name(caption, val[:name]))
                }
              end
          end
          |> Map.put(make_uid(0, -1), Map.new(name: make_event_name(caption, "Other")))
          |> Map.put(make_uid(class_id, 0), Map.new(name: make_event_name(caption, "Unknown")))

        Map.put(attributes, :event_uid, Map.put(uid, :enum, enum))
      end
    )
    |> put_in([:attributes, :event_uid, :_source], name)
  end

  defp make_event_name(caption, name) do
    caption <> ": " <> name
  end

  defp make_event_uid(class_id, key) do
    make_uid(class_id, String.to_integer(Atom.to_string(key)))
  end

  defp make_uid(class_id, id) do
    Integer.to_string(class_id + id)
    |> String.to_atom()
  end

  defp add_class_id(data, name) do
    class_id = data.uid
               |> Integer.to_string()
               |> String.to_atom()

    enum = %{
      :name => data.name,
      :description => data[:description]
    }

    data
    |> put_in([:attributes, :class_id, :enum], %{class_id => enum})
    |> put_in([:attributes, :class_id, :_source], name)
  end

  defp add_category_id(data, name, categories) do
    category_name = data.category
                    |> String.to_atom()

    category = categories[category_name]

    if category == nil do
      exit("#{data.name} has invalid category: #{category_name}")
    end

    update_in(
      data,
      [:attributes, :category_id, :enum],
      fn _enum ->
        id = Integer.to_string(category.id)
             |> String.to_atom()
        %{id => Map.delete(category, :class_id_range)}
      end
    )
    |> put_in([:attributes, :category_id, :_source], name)
  end

  defp attribute_source(home, {name, map}) do
    data =
      Map.update(
        map,
        :attributes,
        [],
        fn attributes ->
          Enum.map(
            attributes,
            fn {key, attribute} ->
              attribute = include(attribute, home)
              {key, Map.put(attribute, :_source, name)}
            end
          )
          |> Map.new()
        end
      )

    {name, data}
  end

  defp resolve_extends(data) do
    Enum.map(data, fn {name, map} -> {name, resolve_extends(name, data, map)} end)
  end

  defp resolve_extends(name, data, map) do
    case map[:extends] do
      nil ->
        map

      key ->
        Logger.info("#{name} extends: #{key}")

        case Map.get(data, String.to_atom(key)) do
          nil ->
            exit("Error: #{map.name} extends undefined class: #{key}")

          base ->
            base = resolve_extends(base[:type], data, base)
            attributes = Utils.deep_merge(base.attributes, map.attributes)

            Map.merge(base, map)
            |> Map.delete(:extends)
            |> Map.put(:attributes, attributes)
        end
    end
  end

  defp update_see_also(classes) do
    Enum.map(classes, fn {name, map} -> update_see_also(name, map, classes) end)
  end

  defp update_see_also(name, map, classes) do
    see_also = update_see_also(map[:see_also], classes)

    if see_also != nil and length(see_also) > 0 do
      {name, Map.put(map, :see_also, see_also)}
    else
      {name, map}
    end
  end

  defp update_see_also(see_also, classes) when is_list(see_also) do
    Enum.map(
      see_also,
      fn name ->
        case Map.get(classes, String.to_atom(name)) do
          nil ->
            nil

          class ->
            {name, class.name}
        end
      end
    )
    |> Enum.filter(fn elem -> elem != nil end)
  end

  defp update_see_also(_see_also, _classes) do
    nil
  end

  defp read_schema_files(acc, path, directory) do
    if File.dir?(path) do
      if Path.basename(path) == directory do
        Logger.info("reading extensions: #{path}")

        read_schema_files(acc, path)
      else
        case File.ls(path) do
          {:ok, files} ->
            files
            |> Stream.map(fn name -> Path.join(path, name) end)
            |> Stream.filter(fn p -> File.dir?(p) end)
            |> Enum.reduce(acc, fn file, map -> read_schema_files(map, file, directory) end)

          error ->
            Logger.warn("unable to access #{path} directory. Error: #{inspect(error)}")
            raise error
        end
      end
    end
  end

  defp read_schema_files(acc, path) do
    if File.dir?(path) do
      case File.ls(path) do
        {:ok, files} ->
          files
          |> Stream.map(fn file -> Path.join(path, file) end)
          |> Enum.reduce(acc, fn file, map -> read_schema_files(map, file) end)

        error ->
          Logger.warn("unable to access #{path} directory. Error: #{inspect(error)}")
          raise error
      end
    else
      if Path.extname(path) == @schema_file do
        data = read_json_file(path)
        Map.put(acc, String.to_atom(data.type), data)
      else
        acc
      end
    end
  end

  defp read_json_file(file) do
    data = File.read!(file)

    case Jason.decode(data, keys: :atoms) do
      {:ok, json} ->
        json

      {:error, error} ->
        message = Jason.DecodeError.message(error)
        Logger.error("invalid JSON file: #{file}. Error: #{message}")
        exit(message)
    end
  end

  defp set_dictionary(%__MODULE__{} = schema, dictionary) do
    struct(schema, dictionary: dictionary)
  end

  defp set_categories(%__MODULE__{} = schema, categories) do
    struct(schema, categories: categories)
  end

  defp set_common(%__MODULE__{} = schema, common) do
    struct(schema, common: common)
  end

  defp set_classes(%__MODULE__{} = schema, classes) do
    struct(schema, classes: classes)
  end

  defp set_objects(%__MODULE__{} = schema, objects) do
    struct(schema, objects: objects)
  end
end
