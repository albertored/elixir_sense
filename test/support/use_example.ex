defmodule ElixirSenseExample.UseExample do
  defmacro __using__(_) do
    quote do
      def example do
        42
      end
    end
  end
end

defmodule ElixirSenseExample.UseExample2 do
  defmacro __using__(_) do
    quote do
      def example do
        42
      end
    end
  end
end
