//
//  Copyright (c) Dr. Michael Lauer Information Technology. All rights reserved.
//

#import "LTBTLESerialTransporter.h"

#import "LTSupportAutomotive.h"

#import "LTBTLEReadCharacteristicStream.h"
#import "LTBTLEWriteCharacteristicStream.h"

NSString* const LTBTLESerialTransporterDidUpdateSignalStrength = @"LTBTLESerialTransporterDidUpdateSignalStrength";
NSString* const LTBTLESerialTransporterDidDiscoverDevice = @"LTBTLESerialTransporterDidDiscoverDevice";

//#define DEBUG_THIS_FILE

#ifdef DEBUG_THIS_FILE
    #define XLOG LOG
#else
    #define XLOG(...)
#endif

@implementation LTBTLESerialTransporter
{
    CBCentralManager* _manager;
    NSUUID* _identifier;
    NSArray<CBUUID*>* _serviceUUIDs;
    CBPeripheral* _adapter;
    CBCharacteristic* _reader;
    CBCharacteristic* _writer;

    // BTLE adapters
    NSMutableArray<CBPeripheral*>* _possibleAdapters;
    
    dispatch_queue_t _dispatchQueue;
    
    LTBTLESerialTransporterConnectionBlock _connectionBlock;
    LTBTLEDeviceDiscoveredBlock _discoveryBlock;
    LTBTLEReadCharacteristicStream* _inputStream;
    LTBTLEWriteCharacteristicStream* _outputStream;
    
    NSNumber* _signalStrength;
    NSTimer* _signalStrengthUpdateTimer;
}

#pragma mark -
#pragma mark Lifecycle

+(instancetype)transporterWithIdentifier:(NSUUID*)identifier serviceUUIDs:(NSArray<CBUUID*>*)serviceUUIDs
{
    return [[self alloc] initWithIdentifier:identifier serviceUUIDs:serviceUUIDs];
}

-(instancetype)initWithIdentifier:(NSUUID*)identifier serviceUUIDs:(NSArray<CBUUID*>*)serviceUUIDs
{
    if ( ! ( self = [super init] ) )
    {
        return nil;
    }
    
    _identifier = identifier;
    _serviceUUIDs = serviceUUIDs;
    
    _dispatchQueue = dispatch_queue_create( [NSStringFromClass(self.class) UTF8String], DISPATCH_QUEUE_SERIAL );
    _possibleAdapters = [NSMutableArray array];
    
    XLOG( @"Created w/ identifier %@, services %@", _identifier, _serviceUUIDs );
    
    return self;
}

-(void)dealloc
{
    [self disconnect];
}

#pragma mark -
#pragma mark API

-(void)connectWithIdentifier:(NSUUID*)identfier block:(LTBTLESerialTransporterConnectionBlock)block
{
    _identifier = identfier;
    _connectionBlock = block;
    if (!_manager) {
        _manager = [[CBCentralManager alloc] initWithDelegate:self queue:_dispatchQueue options:nil];
    }
    NSArray<CBPeripheral*>* peripherals = [_manager retrievePeripheralsWithIdentifiers:@[_identifier]];

    if (!peripherals.count) {
        [_manager scanForPeripheralsWithServices:nil options:nil];
        return;
    }

    _adapter = peripherals.firstObject;
    _adapter.delegate = self;
    LOG( @"DISCOVER (cached) %@", _adapter );
    [_manager connectPeripheral:_adapter options:nil];
}

-(void)disconnect
{
    [self stopUpdatingSignalStrength];
    
    [_inputStream close];
    [_outputStream close];
    
    if ( _adapter )
    {
        [_manager cancelPeripheralConnection:_adapter];
    }
    
    [_possibleAdapters enumerateObjectsUsingBlock:^(CBPeripheral * _Nonnull peripheral, NSUInteger idx, BOOL * _Nonnull stop) {
        [self->_manager cancelPeripheralConnection:peripheral];
    }];

    _adapter = nil;
    _inputStream = nil;
    _outputStream = nil;
    _reader = nil;
    _writer = nil;
}

-(void)startDiscoveryWithBlock:(LTBTLEDeviceDiscoveredBlock)block
{
    _discoveryBlock = block;
    if (!_manager) {
        _manager = [[CBCentralManager alloc] initWithDelegate:self queue:_dispatchQueue options:nil];
    }
}

-(void)stopDiscovery
{
    _discoveryBlock = nil;
    if (_manager.isScanning) {
        [_manager stopScan];
    }
}

-(void)startUpdatingSignalStrengthWithInterval:(NSTimeInterval)interval
{
    [self stopUpdatingSignalStrength];
    
    _signalStrengthUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(onSignalStrengthUpdateTimerFired:) userInfo:nil repeats:YES];
}

-(void)stopUpdatingSignalStrength
{
    [_signalStrengthUpdateTimer invalidate];
    _signalStrengthUpdateTimer = nil;
}

#pragma mark -
#pragma mark NSTimer

-(void)onSignalStrengthUpdateTimerFired:(NSTimer*)timer
{
    if ( _adapter.state != CBPeripheralStateConnected )
    {
        return;
    }
    
    [_adapter readRSSI];
}

#pragma mark -
#pragma mark <CBCentralManagerDelegate>

-(void)centralManagerDidUpdateState:(CBCentralManager *)central
{
    LOG( @"centralManagerDidUpdateState" );
    if ( central.state != CBCentralManagerStatePoweredOn )
    {
        return;
    }

    NSArray<CBPeripheral*>* peripherals = [_manager retrieveConnectedPeripheralsWithServices:_serviceUUIDs];
    if ( peripherals.count )
    {
        LOG( @"CONNECTED (already) %@", _adapter );
        if ( _adapter.state == CBPeripheralStateConnected )
        {
            _adapter = peripherals.firstObject;
            _adapter.delegate = self;
            [self peripheral:_adapter didDiscoverServices:nil];
        }
        else
        {
            [_possibleAdapters addObject:peripherals.firstObject];
            [self centralManager:central didDiscoverPeripheral:peripherals.firstObject advertisementData:@{} RSSI:@127];
        }
        return;
    }
    
    if ( _identifier )
    {
        peripherals = [_manager retrievePeripheralsWithIdentifiers:@[_identifier]];
    }

    if ( !peripherals.count )
    {
        LOG( @"scanForPeripheralsWithServices" );
        // some devices are not advertising the service ID, hence we need to scan for all services
        [_manager scanForPeripheralsWithServices:nil options:nil];
        return;
    }
    
    _adapter = peripherals.firstObject;
    _adapter.delegate = self;
    LOG( @"DISCOVER (cached) %@", _adapter );
    [_manager connectPeripheral:_adapter options:nil];
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral*)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI
{
    if ( _adapter )
    {
        LOG( @"[IGNORING] DISCOVER %@ (RSSI=%@) w/ advertisement %@", peripheral, RSSI, advertisementData );
        return;
    }
    
    LOG( @"DISCOVER %@ (RSSI=%@) w/ advertisement %@", peripheral, RSSI, advertisementData );
    [_possibleAdapters addObject:peripheral];
    peripheral.delegate = self;
    [_manager connectPeripheral:peripheral options:nil];
}

-(void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
    LOG( @"CONNECT %@", peripheral );
    [peripheral discoverServices:_serviceUUIDs];
}

-(void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    LOG( @"Failed to connect %@: %@", peripheral, error );
}

-(void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
    LOG( @"Did disconnect %@: %@", peripheral, error );
    if ( peripheral == _adapter )
    {
        [_inputStream close];
        [_outputStream close];
    }
}

#pragma mark -
#pragma mark <CBPeripheralDelegate>

-(void)peripheral:(CBPeripheral *)peripheral didReadRSSI:(NSNumber *)RSSI error:(NSError *)error
{
    if ( error )
    {
        LOG( @"Could not read signal strength for %@: %@", peripheral, error );
        return;
    }
    
    _signalStrength = RSSI;
    [[NSNotificationCenter defaultCenter] postNotificationName:LTBTLESerialTransporterDidUpdateSignalStrength object:self];
}

-(void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    LOG( @"didDiscoverServices" );
    /*
    if ( _adapter )
    {
        LOG( @"[IGNORING] SERVICES %@: %@", peripheral, peripheral.services );
        return;
    }
     */
    
    if ( error )
    {
        LOG( @"Could not discover services: %@", error );
        return;
    }
    
    if ( !peripheral.services.count )
    {
        LOG( @"Peripheral does not offer requested services" );
    
        [_manager cancelPeripheralConnection:peripheral];
        [_possibleAdapters removeObject:peripheral];
        return;
    }

    _adapter = peripheral;
    _adapter.delegate = self;
    if ( _manager.isScanning )
    {
        [_manager stopScan];
    }
    
    CBService* atCommChannel = peripheral.services.firstObject;
    [peripheral discoverCharacteristics:nil forService:atCommChannel];
}

-(void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
    LOG( @"didDiscoverCharacteristicsForService" );
    for ( CBCharacteristic* characteristic in service.characteristics )
    {
        if ( characteristic.properties & CBCharacteristicPropertyNotify )
        {
            LOG( @"Did see notify characteristic" );
            _reader = characteristic;
            
            //[peripheral readValueForCharacteristic:characteristic];
            [peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
        
        if ( characteristic.properties & CBCharacteristicPropertyWrite )
        {
            LOG( @"Did see write characteristic" );
            if (!_writer) {
            _writer = characteristic;
            }
        }
    }
    
    if ( _reader && _writer )
    {
        if (_discoveryBlock) {
            _discoveryBlock(peripheral);
        }
        [self connectionAttemptSucceeded];
    }
    else
    {
        [self connectionAttemptFailed];
    }
}

-(void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
#ifdef DEBUG_THIS_FILE
    NSString* debugString = [[NSString alloc] initWithData:characteristic.value encoding:NSUTF8StringEncoding];
    NSString* replacedWhitespace = [[debugString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    XLOG( @"%@ >>> %@", peripheral, replacedWhitespace );
#endif
    
    if ( error )
    {
        LOG( @"Could not update value for characteristic %@: %@", characteristic, error );
        return;
    }
    
    [_inputStream characteristicDidUpdateValue];
}

-(void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
    if ( error )
    {
        LOG( @"Could not write to characteristic %@: %@", characteristic, error );
        return;
    }
    
    [_outputStream characteristicDidWriteValue];
}

#pragma mark -
#pragma mark Helpers

-(void)connectionAttemptSucceeded
{
    if (_connectionBlock) {
        _inputStream = [[LTBTLEReadCharacteristicStream alloc] initWithCharacteristic:_reader];
        _outputStream = [[LTBTLEWriteCharacteristicStream alloc] initToCharacteristic:_writer];
        _connectionBlock( _inputStream, _outputStream );
        _connectionBlock = nil;
    }
}

-(void)connectionAttemptFailed
{
    if (_connectionBlock) {
        _connectionBlock( nil, nil );
        _connectionBlock = nil;
    }
}

-(CBPeripheral*)adapter
{
    return _adapter;
}

@end
