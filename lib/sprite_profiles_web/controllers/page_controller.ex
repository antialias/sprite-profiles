defmodule SpriteProfilesWeb.PageController do
  use SpriteProfilesWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
