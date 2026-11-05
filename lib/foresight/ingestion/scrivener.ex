defmodule Foresight.Ingestion.Scrivener do
  @moduledoc false

  alias Foresight.Context
  alias Foresight.Error

  @scrivener_content_type "application/vnd.literatureandlatte.scrivener"

  @spec parse(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def parse(path, opts \\ []) when is_binary(path) do
    path = Path.expand(path)

    with :ok <- validate_bundle(path),
         {:ok, scrivx_path} <- scrivx_path(path),
         {:ok, doc} <- parse_scrivx(scrivx_path, opts),
         {:ok, manuscript} <- manuscript_item(doc),
         {:ok, scenes} <- manuscript_scenes(manuscript, path, opts) do
      {:ok,
       %{
         path: path,
         scrivx_path: scrivx_path,
         identifier: xpath_string("string(/ScrivenerProject/@Identifier)", doc),
         title: Path.basename(path),
         scenes: scenes
       }}
    end
  end

  def ingest(ctx_or_path, path_or_bank_id, opts \\ [])

  @spec ingest(Context.t(), String.t(), keyword()) :: Foresight.Backend.result()
  def ingest(%Context{} = ctx, path, opts) when is_binary(path) do
    Foresight.retain_files(ctx, retain_payload(path, opts),
      document_converter: Foresight.DocumentConverters.Scrivener
    )
  end

  @spec ingest(String.t(), String.t(), keyword()) :: Foresight.Backend.result()
  def ingest(path, bank_id, opts) when is_binary(path) and is_binary(bank_id) do
    ctx = %Context{
      tenant_id: Keyword.get(opts, :tenant_id, "default"),
      mode: normalize_mode(Keyword.get(opts, :mode, :mode_a)),
      bank: bank_id
    }

    ingest(ctx, path, opts)
  end

  @spec dry_run(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def dry_run(path, opts \\ []) when is_binary(path) do
    with {:ok, project} <- parse(path, opts) do
      sample_scene = Enum.find(project.scenes, fn scene -> String.trim(scene.text) != "" end)

      {:ok,
       %{
         path: project.path,
         scrivx_path: project.scrivx_path,
         scene_count: length(project.scenes),
         sample_scene: sample_scene(sample_scene)
       }}
    end
  end

  def document_id(path) when is_binary(path), do: "scrivener:#{Path.basename(Path.expand(path))}"

  defp retain_payload(path, opts) do
    expanded_path = Path.expand(path)

    %{
      "files" => [
        %{
          "path" => expanded_path,
          "filename" => Path.basename(expanded_path),
          "content_type" => @scrivener_content_type,
          "document_id" => Keyword.get(opts, :document_id, document_id(expanded_path)),
          "store_file" => false,
          "metadata" => %{"source" => "scrivener", "scrivener_path" => expanded_path}
        }
      ],
      "request" => %{
        "async" => Keyword.get(opts, :async, false),
        "context" => Keyword.get(opts, :context, "scrivener"),
        "type" => Keyword.get(opts, :type, "experience"),
        "tags" => List.wrap(Keyword.get(opts, :tags, []))
      }
    }
  end

  defp validate_bundle(path) do
    cond do
      not File.dir?(path) ->
        {:error, Error.new(:invalid_request, %{message: "Scrivener bundle not found: #{path}"})}

      Path.extname(path) != ".scriv" ->
        {:error, Error.new(:invalid_request, %{message: "expected a .scriv bundle: #{path}"})}

      true ->
        :ok
    end
  end

  defp scrivx_path(path) do
    case Path.wildcard(Path.join(path, "*.scrivx")) |> Enum.sort() do
      [scrivx_path | _] ->
        {:ok, scrivx_path}

      [] ->
        {:error, Error.new(:invalid_request, %{message: "no .scrivx binder found in #{path}"})}
    end
  end

  # xmerl materialises the whole binder as a term before anything downstream can
  # bound it, so the only place a size limit actually constrains memory is here,
  # BEFORE the parse. A .scrivx is a manifest, not content — real ones are tens
  # to low hundreds of KB even for a large book — so this ceiling is generous.
  @default_max_scrivx_bytes 64 * 1024 * 1024

  defp parse_scrivx(scrivx_path, opts) do
    max_bytes = Keyword.get(opts, :max_scrivx_bytes, @default_max_scrivx_bytes)

    # lstat, not stat: a size gate is meaningless against a thing that has no
    # meaningful size. /dev/zero reports 0 bytes and then feeds xmerl an infinite
    # stream of them until the VM dies; a FIFO reports 0 and blocks forever
    # waiting for a writer. Both sail through a size check. Demand a regular file
    # and the whole class goes away — and lstat rather than stat so a symlink
    # pointing at either one is refused rather than followed (security re-audit).
    with {:ok, %File.Stat{size: size, type: type}} <- File.lstat(scrivx_path),
         :ok <- check_scrivx_type(type, scrivx_path),
         :ok <- check_scrivx_size(size, max_bytes, scrivx_path) do
      try do
        {doc, _rest} = xmerl_file(String.to_charlist(scrivx_path), quiet: true)
        {:ok, doc}
      catch
        :exit, reason ->
          {:error,
           Error.new(:invalid_request, %{
             message: "failed to parse Scrivener binder #{scrivx_path}: #{inspect(reason)}"
           })}
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, posix} ->
        {:error,
         Error.new(:invalid_request, %{
           message: "cannot stat Scrivener binder #{scrivx_path}: #{inspect(posix)}"
         })}
    end
  end

  defp check_scrivx_type(:regular, _scrivx_path), do: :ok

  defp check_scrivx_type(type, scrivx_path) do
    {:error,
     Error.new(:invalid_request, %{
       message: "Scrivener binder #{scrivx_path} is not a regular file",
       type: type
     })}
  end

  defp check_scrivx_size(size, max_bytes, scrivx_path) when size > max_bytes do
    {:error,
     Error.new(:invalid_request, %{
       message: "Scrivener binder #{scrivx_path} exceeds the maximum size",
       size: size,
       max_bytes: max_bytes
     })}
  end

  defp check_scrivx_size(_size, _max_bytes, _scrivx_path), do: :ok

  defp manuscript_item(doc) do
    exact =
      xmerl_xpath(
        ~c"/ScrivenerProject/Binder/BinderItem[@Type=\"DraftFolder\" and Title/text()=\"Manuscript\"]",
        doc
      )

    fallback =
      fn ->
        xmerl_xpath(~c"/ScrivenerProject/Binder/BinderItem[@Type=\"DraftFolder\"]", doc)
      end

    case exact do
      [item | _] ->
        {:ok, item}

      [] ->
        case fallback.() do
          [item | _] ->
            {:ok, item}

          [] ->
            {:error,
             Error.new(:invalid_request, %{message: "no Manuscript DraftFolder found in .scrivx"})}
        end
    end
  end

  # A declared ceiling on scenes, checked after collection. Be clear about what
  # this is and is not: the real memory bound is @default_max_scrivx_bytes above,
  # applied before xmerl builds the tree. This one does NOT stream — it refuses an
  # over-large manuscript rather than preventing it from being built. It earns its
  # place by turning "silently ingests 400k scenes" into a legible error, not by
  # capping peak memory. Override with :max_scenes.
  @default_max_scenes 20_000

  defp manuscript_scenes(manuscript, bundle_path, opts) do
    max_scenes = Keyword.get(opts, :max_scenes, @default_max_scenes)

    try do
      scenes =
        manuscript
        |> child_binder_items()
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, sibling_index} ->
          collect_scenes(item, bundle_path, [], sibling_index, opts)
        end)
        |> Enum.with_index()
        |> Enum.map(fn {scene, order_index} -> Map.put(scene, :order_index, order_index) end)

      if length(scenes) > max_scenes do
        {:error,
         Error.new(:invalid_request, %{
           message: "Scrivener bundle exceeds the maximum scene count",
           scene_count: length(scenes),
           max_scenes: max_scenes
         })}
      else
        {:ok, scenes}
      end
    catch
      {:scrivener_error, %Error{} = error} -> {:error, error}
    end
  end

  defp collect_scenes(item, bundle_path, binder_path, sibling_index, opts) do
    case xpath_string("string(@Type)", item) do
      "Text" ->
        item
        |> scene(bundle_path, binder_path, sibling_index, opts)
        |> case do
          {:ok, nil} -> []
          {:ok, scene} -> [scene]
          {:error, %Error{} = error} -> throw({:scrivener_error, error})
        end

      type when type in ["Folder", "DraftFolder"] ->
        next_path = append_binder_title(binder_path, title(item))

        item
        |> child_binder_items()
        |> Enum.with_index()
        |> Enum.flat_map(fn {child, child_index} ->
          collect_scenes(child, bundle_path, next_path, child_index, opts)
        end)

      _other ->
        []
    end
  end

  defp scene(item, bundle_path, binder_path, sibling_index, opts) do
    uuid = xpath_string("string(@UUID)", item)

    with {:ok, text} <- content_text(bundle_path, uuid, opts) do
      text = normalize_text(text)

      if text == "" do
        {:ok, nil}
      else
        {:ok,
         %{
           uuid: uuid,
           title: title(item),
           synopsis: synopsis(item),
           binder_path: binder_path,
           sibling_index: sibling_index,
           label_id: optional_text("string(MetaData/LabelID/text())", item),
           keyword_ids: keyword_ids(item),
           text: text
         }}
      end
    end
  end

  defp content_text(_bundle_path, "", _opts), do: {:ok, ""}

  defp content_text(bundle_path, uuid, opts) do
    with {:ok, content_path} <- content_path(bundle_path, uuid) do
      if File.exists?(content_path) do
        decode_rtf(content_path, opts)
      else
        {:ok, ""}
      end
    end
  end

  # The UUID is an attacker-controlled XML attribute read straight out of the
  # .scrivx, and a .scriv bundle is a shareable artifact that can arrive from
  # anyone. Interpolated into a path unchecked it is a traversal primitive:
  # UUID="../../../../srv/someone/private" reads that directory's content.rtf,
  # and even a miss leaks existence through File.exists?. Path.join/1 does not
  # sanitise "..".
  #
  # Two independent guards, because either alone is a single point of failure:
  # the segment must look like a Scrivener identifier, AND the expanded result
  # must still sit inside the bundle. Real identifiers are UUIDs; the test
  # fixtures use names like SCENE-1, so the character class stays permissive
  # while still excluding every separator.
  defp content_path(bundle_path, uuid) do
    root = Path.expand(bundle_path)
    data_root = Path.expand(Path.join([root, "Files", "Data"]))
    candidate = Path.expand(Path.join([data_root, uuid, "content.rtf"]))

    cond do
      not Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, uuid) or uuid in [".", ".."] ->
        {:error, unsafe_uuid_error(uuid)}

      not String.starts_with?(candidate, data_root <> "/") ->
        {:error, unsafe_uuid_error(uuid)}

      true ->
        with :ok <- reject_symlinked_components(root, ["Files", "Data", uuid, "content.rtf"]) do
          {:ok, candidate}
        end
    end
  end

  # Third guard, and the one the first two cannot cover: Path.expand does NOT
  # resolve symlinks, so the containment check above compares literal strings
  # while the OS follows links. A .scriv bundle is a directory that travels as a
  # zip or tarball, and archives carry symlinks — make Files/Data a link to /etc
  # and every lexical check passes while the read lands outside the bundle
  # (security re-audit).
  #
  # Walk the chain component by component with lstat, which does not follow, and
  # refuse if any link appears. A missing component is not a failure: content_text/3
  # treats an absent content.rtf as an empty scene, and nothing that is never
  # opened can escape anywhere.
  defp reject_symlinked_components(root, segments) do
    Enum.reduce_while(segments, {:ok, root}, fn segment, {:ok, parent} ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, symlinked_component_error(path)}}

        {:ok, %File.Stat{}} ->
          {:cont, {:ok, path}}

        {:error, :enoent} ->
          {:halt, :missing}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.new(:invalid_request, %{
              message: "cannot inspect Scrivener bundle component #{path}: #{inspect(reason)}"
            })}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      :missing -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  defp symlinked_component_error(path) do
    Error.new(:invalid_request, %{
      message: "Scrivener bundle contains a symlinked path component",
      path: path
    })
  end

  defp unsafe_uuid_error(uuid) do
    Error.new(:invalid_request, %{
      message: "Scrivener bundle contains an unsafe document UUID",
      uuid: uuid
    })
  end

  defp decode_rtf(content_path, opts) do
    case Keyword.get(opts, :rtf_decoder, :textutil) do
      :textutil ->
        decode_rtf_with_textutil(content_path)

      module when is_atom(module) ->
        module.decode(content_path)
    end
  end

  defp decode_rtf_with_textutil(content_path) do
    case System.find_executable("textutil") do
      nil ->
        {:error,
         Error.new(:unavailable, %{
           message: "textutil is required to decode Scrivener RTF content on this system"
         })}

      executable ->
        case System.cmd(executable, ["-convert", "txt", "-stdout", content_path],
               stderr_to_stdout: true
             ) do
          {text, 0} ->
            {:ok, text}

          {output, status} ->
            {:error,
             Error.new(:invalid_request, %{
               message: "textutil failed for #{content_path} with status #{status}: #{output}"
             })}
        end
    end
  rescue
    error ->
      {:error,
       Error.new(:invalid_request, %{
         message: "failed to decode Scrivener RTF #{content_path}: #{Exception.message(error)}"
       })}
  end

  defp normalize_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/<(?:\$Scr|!\$Scr)[^>\n]*>/u, "")
    |> String.replace(<<0>>, "")
    |> String.trim()
  end

  defp child_binder_items(item), do: xmerl_xpath(~c"Children/BinderItem", item)

  defp title(item), do: optional_text("string(Title/text())", item) || ""

  defp synopsis(item) do
    optional_text("string(MetaData/Synopsis/text())", item) ||
      optional_text("string(Synopsis/text())", item)
  end

  defp keyword_ids(item) do
    ~c"Keywords/KeywordID/text()"
    |> xmerl_xpath(item)
    |> Enum.map(&xml_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp append_binder_title(path, ""), do: path
  defp append_binder_title(path, title), do: path ++ [title]

  defp xpath_string(xpath, item) do
    case xmerl_xpath(String.to_charlist(xpath), item) do
      {:xmlObj, :string, value} -> List.to_string(value)
      value when is_list(value) -> value |> Enum.map(&xml_text/1) |> Enum.join("")
      _other -> ""
    end
  end

  defp optional_text(xpath, item) do
    case xpath_string(xpath, item) |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp xml_text({:xmlText, _parents, _pos, _attrs, value, :text}), do: List.to_string(value)
  defp xml_text(_other), do: ""

  defp xmerl_file(path, opts), do: apply(:xmerl_scan, :file, [path, opts])
  defp xmerl_xpath(xpath, item), do: apply(:xmerl_xpath, :string, [xpath, item])

  defp sample_scene(nil), do: nil

  defp sample_scene(scene) do
    %{
      uuid: scene.uuid,
      title: scene.title,
      binder_path: scene.binder_path,
      order_index: scene.order_index,
      text: String.slice(scene.text, 0, 500)
    }
  end

  defp normalize_mode(mode) when mode in [:mode_a, :mode_b, :mode_c], do: mode
  defp normalize_mode("mode_a"), do: :mode_a
  defp normalize_mode("mode_b"), do: :mode_b
  defp normalize_mode("mode_c"), do: :mode_c
end
