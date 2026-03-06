using System.ComponentModel;
using System.Text.Json.Serialization;
using Microsoft.SemanticKernel;

public class LightsPlugin
{
   // Mock data for the lights
   private readonly List<Light> lights =
   [
      new Light { Id = 1, Name = "Table Lamp", IsOn = false },
      new Light { Id = 2, Name = "Porch light", IsOn = false },
      new Light { Id = 3, Name = "Chandelier", IsOn = true }
   ];

   public enum LightState
   {
      Off = 0,
      On = 1
   }

   [KernelFunction()]
   [Description("Gets a list of lights and their current state")]
   public List<Light> GetLights()
   {
      return lights;
   }

   [KernelFunction()]
   [Description("Changes the state of the light")]
   public Light? ChangeState(int id, LightState newState)
   {
      var light = lights.FirstOrDefault(light => light.Id == id);

      if (light == null)
      {
         return null;
      }

      // Update the light with the new state
      light.IsOn = newState == LightState.On;

      return light;
   }

   [KernelFunction()]
   [Description("Add a new light to the list of available lights")]
   public Light? AddLight(string name, LightState newState)
   {
      var newLight = new Light
      {
         Id = lights.Max(l => l.Id) + 1,
         Name = name,
         IsOn = newState == LightState.On
      };

      lights.Add(newLight);
      return newLight;
   }

   [KernelFunction()]
   [Description("Remove a light from the list of available lights")]
   public bool RemoveLight(int id)
   {
      var light = lights.FirstOrDefault(light => light.Id == id);

      if (light == null)
      {
         return false;
      }

      lights.Remove(light);
      return true;
   }
}

public class Light
{
   [JsonPropertyName("id")]
   public int Id { get; set; }

   [JsonPropertyName("name")]
   public required string Name { get; set; }

   [JsonPropertyName("is_on")]
   public bool? IsOn { get; set; }
}