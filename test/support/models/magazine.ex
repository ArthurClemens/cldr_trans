defmodule Cldr.Trans.Magazine do
  use Ecto.Schema
  use Cldr.Trans, translates: [:title, :body], default_locale: :en

  schema "magazine" do
    field :title, :string
    field :body, :string
    translations :translations, Translations, [:es, :it, :de]
  end
end
