use Mix.Config

config :ethereumex, url: System.get_env("ETHEREUM_URL")

config :ethereumex, client_type: :ws
