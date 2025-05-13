/*
 * Adafruit nRF52840 Feather Express - iBeacon
 * 
 * Este código configura o Adafruit nRF52840 Feather Express como um beacon iBeacon
 * com UUID, Major e Minor específicos para ser detectado por um aplicativo iOS.
 * 
 * Baseado no exemplo da Adafruit para BLEBeacon
 */

#include <bluefruit.h>

// UUID do beacon (gerado aleatoriamente)
uint8_t beaconUuid[16] = {
  0xE2, 0x5B, 0x8D, 0x3C, 0x94, 0x7A, 0x45, 0x2F, 
  0xA1, 0x3F, 0x58, 0x9C, 0xB7, 0x06, 0xD2, 0xE5
};

// Valores de Major e Minor para identificação do beacon
#define BEACON_MAJOR    0x0001
#define BEACON_MINOR    0x0002

// RSSI a 1 metro de distância (calibrado para -59 dBm)
#define BEACON_RSSI     -59

// Manufacturer ID - 0x004C é Apple (para compatibilidade com iOS)
#define MANUFACTURER_ID  0x004C

// Objeto beacon com UUID, Major, Minor e RSSI
BLEBeacon beacon(beaconUuid, BEACON_MAJOR, BEACON_MINOR, BEACON_RSSI);

void setup() {
  Serial.begin(115200);
  
  // Aguarda a conexão serial para facilitar o debug (opcional)
  // while (!Serial) delay(10);
  
  Serial.println("Adafruit nRF52840 Feather Express - iBeacon");
  Serial.println("-------------------------------------------");

  // Inicializa o Bluefruit
  Bluefruit.begin();
  
  // Desliga o LED para economizar energia
  Bluefruit.autoConnLed(false);
  
  // Define a potência de transmissão (valores válidos: -40, -30, -20, -16, -12, -8, -4, 0, 4)
  Bluefruit.setTxPower(0);
  
  // Define o nome do dispositivo (opcional, não será visível no modo beacon)
  Bluefruit.setName("Adafruit_Beacon");

  // Define o Manufacturer ID para o beacon
  beacon.setManufacturer(MANUFACTURER_ID);

  // Configura e inicia o advertising
  startAdv();

  // Exibe informações do beacon no console
  Serial.println("Beacon configurado com os seguintes parâmetros:");
  Serial.print("UUID: ");
  for (int i = 0; i < 16; i++) {
    if (beaconUuid[i] < 0x10) Serial.print("0");
    Serial.print(beaconUuid[i], HEX);
    if (i < 15) Serial.print("-");
  }
  Serial.println();
  
  Serial.print("Major: 0x");
  Serial.println(BEACON_MAJOR, HEX);
  
  Serial.print("Minor: 0x");
  Serial.println(BEACON_MINOR, HEX);
  
  Serial.print("RSSI @ 1m: ");
  Serial.println(BEACON_RSSI);
  
  Serial.print("Manufacturer ID: 0x");
  Serial.println(MANUFACTURER_ID, HEX);
  
  Serial.println("\nBeacon está transmitindo! Utilize um aplicativo iOS para detectá-lo.");

  // Suspende o loop para economizar energia
  suspendLoop();
}

void startAdv(void) {
  // Configura o pacote de advertising com os dados do beacon
  Bluefruit.Advertising.setBeacon(beacon);

  // Configura o pacote de resposta de scan (opcional)
  // Como não há espaço para o nome no pacote de advertising principal
  Bluefruit.ScanResponse.addName();
  
  /* Inicia o advertising
   * - Tipo: Não-conectável, escaneável, não-direcionado (padrão para iBeacon)
   * - Intervalo: 100ms (160 * 0.625ms)
   * - Não para de transmitir (0 = continua indefinidamente)
   */
  Bluefruit.Advertising.setType(BLE_GAP_ADV_TYPE_NONCONNECTABLE_SCANNABLE_UNDIRECTED);
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(160, 160);    // em unidades de 0.625 ms
  Bluefruit.Advertising.setFastTimeout(30);       // tempo em modo rápido (segundos)
  Bluefruit.Advertising.start(0);                 // 0 = não para de transmitir
}

void loop() {
  // O loop está suspenso para economizar energia
  // O CPU não executará o loop()
}
