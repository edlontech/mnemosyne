defmodule Mnemosyne.ErrorsTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Errors
  alias Mnemosyne.Errors.Framework.RepoError
  alias Mnemosyne.Errors.Unknown.Unknown

  describe "Splode error creation" do
    test "creates an unknown error with a string message" do
      error = Unknown.exception(error: "something went wrong")

      assert %Unknown{} = error
      assert Exception.message(error) == "something went wrong"
    end

    test "creates an unknown error with a non-string value" do
      error = Unknown.exception(error: {:unexpected, 42})

      assert %Unknown{} = error
      assert Exception.message(error) == inspect({:unexpected, 42})
    end
  end

  describe "to_class/1" do
    test "aggregates a single error into its error class" do
      error = Unknown.exception(error: "boom")
      class = Errors.to_class(error)

      assert %{class: :unknown, errors: _} = class
    end

    test "aggregates multiple errors" do
      e1 = Unknown.exception(error: "first")
      e2 = Unknown.exception(error: "second")
      class = Errors.to_class([e1, e2])

      assert %{class: :unknown, errors: errors} = class
      assert length(errors) == 2
    end
  end

  describe "splode_error?/1" do
    test "returns true for a Splode error" do
      error = Unknown.exception(error: "test")
      assert Errors.splode_error?(error)
    end

    test "returns false for a plain map" do
      refute Errors.splode_error?(%{not: "an error"})
    end

    test "returns false for a non-struct value" do
      refute Errors.splode_error?("just a string")
    end
  end

  describe "RepoError" do
    test "formats message with repo_id and reason" do
      error = RepoError.exception(repo_id: :my_repo, reason: :already_open)

      assert %RepoError{} = error
      assert Exception.message(error) == "repo :my_repo: repository is already open"
    end

    test "formats message with reason only" do
      error = RepoError.exception(reason: :already_open)

      assert %RepoError{} = error
      assert Exception.message(error) == "repository is already open"
    end

    test "formats unknown reason via inspect" do
      error = RepoError.exception(repo_id: :test, reason: {:custom, "details"})

      assert Exception.message(error) == "repo :test: {:custom, \"details\"}"
    end

    test "belongs to the framework error class" do
      error = RepoError.exception(repo_id: :x, reason: :already_open)
      class = Errors.to_class(error)

      assert %{class: :framework} = class
    end
  end

  describe "unknown error handling" do
    test "to_error wraps a plain string into the unknown error" do
      error = Errors.to_error("raw failure")
      assert %Unknown{} = error
      assert Exception.message(error) == "raw failure"
    end

    test "to_error wraps an arbitrary term" do
      error = Errors.to_error({:db, :timeout})
      assert %Unknown{} = error
      assert Exception.message(error) =~ "timeout"
    end
  end
end
