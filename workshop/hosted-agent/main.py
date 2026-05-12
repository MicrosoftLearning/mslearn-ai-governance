import os
from typing import Annotated
from datetime import datetime, timezone as tz

from pydantic import Field
from agent_framework import Agent, tool
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential


@tool(approval_mode="never_require")
def get_current_time(
    timezone: Annotated[str, Field(description="IANA timezone name, e.g. 'America/New_York', 'Europe/London', 'Asia/Tokyo'")]
) -> str:
    """Get the current date and time for a given timezone."""
    import zoneinfo
    try:
        zone = zoneinfo.ZoneInfo(timezone)
        now = datetime.now(zone)
        return f"Current time in {timezone}: {now.strftime('%Y-%m-%d %H:%M:%S %Z')}"
    except Exception as e:
        return f"Could not get time for timezone '{timezone}': {e}"


@tool(approval_mode="never_require")
def get_weather(
    location: Annotated[str, Field(description="City name, e.g. 'Seattle', 'London', 'Tokyo'")]
) -> str:
    """Get the current weather for a given location (simulated)."""
    import hashlib
    # Deterministic but varied simulated weather based on location + date
    seed = hashlib.md5(f"{location}{datetime.now(tz.utc).strftime('%Y-%m-%d')}".encode()).hexdigest()
    conditions = ["sunny", "partly cloudy", "cloudy", "rainy", "windy", "snowy"]
    condition = conditions[int(seed[:2], 16) % len(conditions)]
    temp_c = 5 + (int(seed[2:4], 16) % 30)
    humidity = 30 + (int(seed[4:6], 16) % 50)
    return f"Weather in {location}: {condition}, {temp_c} deg C, humidity {humidity}%"


def main():
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=DefaultAzureCredential(),
    )

    agent = Agent(
        client=client,
        instructions=(
            "You are a helpful assistant that provides current time and weather information. "
            "Use the get_current_time tool for time queries and get_weather tool for weather queries. "
            "Be concise and friendly in your responses."
        ),
        tools=[get_current_time, get_weather],
        # History will be managed by the hosting infrastructure, thus there
        # is no need to store history by the service. Learn more at:
        # https://developers.openai.com/api/reference/resources/responses/methods/create
        default_options={"store": False},
    )

    server = ResponsesHostServer(agent)
    server.run()


if __name__ == "__main__":
    main()