using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using ModelContextProtocol.Server;

namespace Samples.LightTheLight.Mcp;

public class Light
{
   [JsonPropertyName("id")]
   public int Id { get; set; }

   [JsonPropertyName("name")]
   public required string Name { get; set; }

   [JsonPropertyName("is_on")]
   public bool? IsOn { get; set; }
}

public class Lights
{
   private readonly List<Light> _lights =
   [
      new Light { Id = 1, Name = "Table Lamp", IsOn = false },
      new Light { Id = 2, Name = "Porch light", IsOn = false },
      new Light { Id = 3, Name = "Chandelier", IsOn = true }
   ];

   public List<Light> GetLights() => _lights;

   public Light? ChangeLightState(int id, bool isOn)
   {
      var light = _lights.FirstOrDefault(l => l.Id == id);
      if (light == null) return null;
      light.IsOn = isOn;
      return light;
   }

   public Light AddLight(string name, bool isOn)
   {
      var newLight = new Light
      {
         Id = _lights.Count > 0 ? _lights.Max(l => l.Id) + 1 : 1,
         Name = name,
         IsOn = isOn
      };
      _lights.Add(newLight);
      return newLight;
   }

   public bool RemoveLight(int id)
   {
      var light = _lights.FirstOrDefault(l => l.Id == id);
      if (light == null) return false;
      _lights.Remove(light);
      return true;
   }
}

[McpServerToolType]
public class LightsTools
{
   [McpServerTool, Description("Gets a list of lights and their current state")]
   public static string GetLights(Lights plugin)
   {
      var lights = plugin.GetLights();
      Console.WriteLine($"📡 MCP Call: GetLights -> {lights.Count} light(s)");
      return JsonSerializer.Serialize(lights);
   }

   [McpServerTool, Description("Changes the state of the light")]
   public static async Task<string> ChangeState(
      [Description("The ID of the light to change")] int id,
      [Description("True to turn the light on, false to turn it off")] bool isOn,
      Lights plugin,
      WebSocketRequestHandler wsHandler)
   {
      var light = plugin.ChangeLightState(id, isOn);
      var stateStr = isOn ? "on" : "off";
      Console.WriteLine($"📡 MCP Call: ChangeState(id={id}, state={stateStr}) -> {light?.Name ?? "not found"}");
      if (light != null) await wsHandler.BroadcastLightUpdate();
      return light != null ? JsonSerializer.Serialize(light) : "Light not found";
   }

   [McpServerTool, Description("Add a new light to the list of available lights")]
   public static async Task<string> AddLight(
      [Description("The name of the new light")] string name,
      [Description("True if the light should start on, false for off")] bool isOn,
      Lights plugin,
      WebSocketRequestHandler wsHandler)
   {
      var light = plugin.AddLight(name, isOn);
      Console.WriteLine($"📡 MCP Call: AddLight(name={name}, isOn={isOn}) -> id={light.Id}");
      await wsHandler.BroadcastLightUpdate();
      return JsonSerializer.Serialize(light);
   }

   [McpServerTool, Description("Remove a light from the list of available lights")]
   public static async Task<string> RemoveLight(
      [Description("The ID of the light to remove")] int id,
      Lights plugin,
      WebSocketRequestHandler wsHandler)
   {
      var result = plugin.RemoveLight(id);
      Console.WriteLine($"📡 MCP Call: RemoveLight(id={id}) -> {(result ? "removed" : "not found")}");
      if (result) await wsHandler.BroadcastLightUpdate();
      return result ? "Light removed successfully" : "Light not found";
   }
}
