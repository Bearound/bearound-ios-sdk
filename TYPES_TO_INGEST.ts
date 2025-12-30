export type BeaconProximity = "immediate" | "near" | "far" | "unknown";
export type NetworkType = "wifi" | "cellular" | "none" | "unknown";
export type CellularGeneration = "2G" | "3G" | "4G" | "5G" | "unknown";
export type IOSLocationPermission = "not_determined" | "restricted" | "denied" | "authorized_when_in_use" | "authorized_always";
export type AndroidLocationPermission = "not_determined" | "restricted" | "denied" | "authorized_fine" | "authorized_coarse" | "authorized_background";
export type LocationPermission = IOSLocationPermission | AndroidLocationPermission;
export type LocationAccuracy = "full" | "reduced";
export type NotificationPermission = "authorized" | "denied" | "not_determined";
export type IOSBluetoothState = "powered_on" | "powered_off" | "unsupported" | "unauthorized";
export type AndroidBluetoothState = "powered_on" | "powered_off" | "unsupported" | "unauthorized" | "turning_on" | "turning_off";
export type BluetoothState = IOSBluetoothState | AndroidBluetoothState;
export type ThermalState = "nominal" | "fair" | "serious" | "critical";

export interface BeaconMetadata {
	battery: number;
	firmware: string;
	movements: number;
	temperature: number;
	txPower?: number;
	rssiFromBLE?: number;
	isConnectable?: boolean;
}

export interface Beacon {
	uuid: string;
	major: number;
	minor: number;
	rssi: number;
	accuracy: number;
	proximity: BeaconProximity;
	txPower?: number;
	timestamp: number;
	metadata?: BeaconMetadata;
}

export interface DeviceLocation {
	latitude: number;
	longitude: number;
	accuracy?: number;
	altitude?: number;
	altitudeAccuracy?: number;
	heading?: number;
	course?: number;
	courseAccuracy?: number;
	speed?: number;
	speedAccuracy?: number;
	floor?: number;
	sourceInfo?: string;
	timestamp: number;
}

export interface DeviceHardware {
	manufacturer: string;
	model: string;
	os: string;
	osVersion: string;
}

export interface DeviceScreen {
	width: number;
	height: number;
}

export interface DeviceBattery {
	level: number;
	isCharging: boolean;
	lowPowerMode?: boolean;
}

export interface DeviceNetwork {
	type: NetworkType;
	cellularGeneration?: CellularGeneration;
	wifiSSID?: string;
}

export type PlatformSpecificPermissions<T extends "ios" | "android"> = {
	location: T extends "ios" ? IOSLocationPermission : AndroidLocationPermission;
	notifications: NotificationPermission;
	bluetooth: T extends "ios" ? IOSBluetoothState : AndroidBluetoothState;
	locationAccuracy?: LocationAccuracy;
	adTrackingEnabled: boolean;
	advertisingId?: string;
};

export interface DevicePermissions extends PlatformSpecificPermissions<"ios" | "android"> {}

export interface DeviceMemory {
	totalMb: number;
	availableMb: number;
}

export interface DeviceAppState {
	inForeground: boolean;
	uptimeMs: number;
	coldStart: boolean;
}

export interface Device<T extends "ios" | "android" = "ios" | "android"> {
	deviceId: string;
	timestamp: number;
	timezone: string;
	hardware: DeviceHardware;
	screen: DeviceScreen;
	battery: DeviceBattery;
	network: DeviceNetwork;
	permissions: PlatformSpecificPermissions<T>;
	memory: DeviceMemory;
	appState: DeviceAppState;
	deviceName: string;
	systemLanguage: string;
	thermalState: ThermalState;
	systemUptimeMs: number;
	carrierName?: string;
	availableStorageMb?: number;
	deviceLocation?: DeviceLocation;
}

export interface SDK {
	version: string;
	platform: "ios" | "android";
	appId: string;
	build: number;
}

export interface UserProperties {
	internalId?: string;
	email?: string;
	name?: string;
	[key: string]: string | number | boolean | undefined;
}

export interface BeAroundAPIPayload<T extends "ios" | "android" = "ios" | "android"> {
	beacons: Beacon[];
	device: Device<T>;
	sdk: T extends "ios" ? { version: string; platform: "ios"; appId: string; build: number; }
	      : T extends "android" ? { version: string; platform: "android"; appId: string; build: number; }
	      : SDK;
	userProperties?: UserProperties;
}
