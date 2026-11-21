const options = {
  dom_id: "#swagger-ui",
  url: "/docs/openapi.yaml",
  presets: [SwaggerUIBundle.presets.apis],
  layout: "BaseLayout",
  deepLinking: true,
  supportedSubmitMethods: [],
  validatorUrl: null,
  queryConfigEnabled: false,
  persistAuthorization: false,
};
if (new URLSearchParams(location.search).get("contract") === "nutrition") {
  options.url = "/docs/nutrition.yaml";
}
SwaggerUIBundle(options);
