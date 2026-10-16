`timescale 1ns / 1ps
//****************************************Copyright (c)***********************************//
//ԭ�Ӹ����߽�ѧƽ̨��www.yuanzige.com
//����֧�֣�www.openedv.com
//�Ա����̣�http://openedv.taobao.com 
//��ע΢�Ź���ƽ̨΢�źţ�"����ԭ��"����ѻ�ȡZYNQ & FPGA & STM32 & LINUX���ϡ�
//��Ȩ���У�����ؾ���
//Copyright(C) ����ԭ�� 2018-2028
//All rights reserved
//----------------------------------------------------------------------------------------
// File name:           ms72xx_ctl
// Last modified Date:  2023/9/21 9:30:00
// Last Version:        V1.1
// Descriptions:        ��ƵоƬ����ģ��
//----------------------------------------------------------------------------------------
// Created by:          ����ԭ��
// Created date:        2023/9/21 9:30:00
// Version:             V1.0
// Descriptions:        The original version
//
//----------------------------------------------------------------------------------------
//****************************************************************************************//

module ms72xx_ctl(
    input       clk,
    input       rst_n,
    
    output      rstn_out,    //оƬ��λ�źţ�����Ч
    output      init_over,   //����ȫ����ɱ�־
    output      iic_scl ,   
    inout       iic_sda 
);


//parameter define
parameter SLAVE_ADDR_MS7210 = 7'h2b   ; //������ַ
parameter SLAVE_ADDR_MS7200 = 7'h59   ; //������ַ
parameter BIT_CTRL   = 1'b1           ; //�ֽڵ�ַΪ16λ  0:8λ 1:16λ
parameter CLK_FREQ   = 27'd25_000_000 ; //i2c_driģ�������ʱ��Ƶ�� 
parameter I2C_FREQ   = 18'd250_000    ; //I2C��SCLʱ��Ƶ��,������400KHz

//wire define
wire        i2c_exec          ;  //I2C����ִ���ź�
wire        i2c_exec_tx       ;  //���Ͷ�I2C����ִ���ź�
wire        i2c_exec_rx       ;  //���ն�I2C����ִ���ź�
wire [23:0] i2c_data          ;  //I2CҪ���õĵ�ַ������(��16λ��ַ,��8λ����) 
wire [23:0] i2c_data_tx       ;  
wire [23:0] i2c_data_rx       ;             
wire        i2c_done          ;  //I2C�Ĵ�����������ź�
wire        i2c_done_tx       ;  
wire        i2c_done_rx       ;  
wire        i2c_dri_clk       ;  //I2C����ʱ��
wire [ 7:0] i2c_data_r        ;  //I2C����������
wire [ 7:0] i2c_data_r_tx     ;  //I2C����������
wire [ 7:0] i2c_data_r_rx     ;  //I2C����������
wire        i2c_rh_wl         ;  //I2C��д�����ź�
wire        i2c_rh_wl_tx      ;  //I2C��д�����ź�
wire        i2c_rh_wl_rx      ;  //I2C��д�����ź�
wire [ 6:0] slave_addr        ;  //I2C������ַ
wire        init_over_rx      ;  //MS7200��������ź�

//*****************************************************
//**                    main code
//*****************************************************

assign slave_addr = (init_over_rx == 1'b1 && init_over == 1'b0) ? SLAVE_ADDR_MS7210 : SLAVE_ADDR_MS7200; 
assign i2c_exec = (init_over_rx == 1'b1 && init_over == 1'b0) ? i2c_exec_tx : i2c_exec_rx; 
assign i2c_data = (init_over_rx == 1'b1 && init_over == 1'b0) ? i2c_data_tx : i2c_data_rx; 
assign i2c_rh_wl = (init_over_rx == 1'b1 && init_over == 1'b0) ? i2c_rh_wl_tx : i2c_rh_wl_rx;  
assign i2c_done_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? i2c_done : 1'b0;
assign i2c_done_rx = (init_over_rx == 1'b1 && init_over == 1'b0) ? 1'b1 : i2c_done;  
assign i2c_data_r_tx = (init_over_rx == 1'b1 && init_over == 1'b0) ? i2c_data_r : 8'd0;
assign i2c_data_r_rx = (init_over_rx == 1'b1 && init_over == 1'b0) ? 8'd0 : i2c_data_r;  

//I2C����ģ��
i2c_ms7200_cfg u_i2c_ms7200_cfg(
    .clk                (i2c_dri_clk),
    .rst_n              (rst_n),
            
    .i2c_exec           (i2c_exec_rx),
    .i2c_data           (i2c_data_rx),
    .i2c_rh_wl          (i2c_rh_wl_rx),        //I2C��д�����ź�
    .i2c_done           (i2c_done_rx), 
    .i2c_data_r         (i2c_data_r_rx),   
    .rstn_out           (rstn_out),       
    .init_done          (init_over_rx)         //����ȫ����ɱ�־
    );    
    
//I2C����ģ��
i2c_ms7210_cfg u_i2c_ms7210_cfg(
    .clk                (i2c_dri_clk),
    .rst_n              (rst_n && init_over_rx),
            
    .i2c_exec           (i2c_exec_tx),
    .i2c_data           (i2c_data_tx),
    .i2c_rh_wl          (i2c_rh_wl_tx),        //I2C��д�����ź�
    .i2c_done           (i2c_done_tx), 
    .i2c_data_r         (i2c_data_r_tx),   
    .rstn_out           (),       
    .init_done          (init_over)         //����ȫ����ɱ�־
    );       

//I2C����ģ��
i2c_dri #(
    .CLK_FREQ           (CLK_FREQ  ),              
    .I2C_FREQ           (I2C_FREQ  ) 
    )
u_i2c_dri(
    .clk                (clk),
    .rst_n              (rst_n     ),

    .i2c_exec           (i2c_exec  ),   
    .bit_ctrl           (BIT_CTRL ), 
    .slave_addr         (slave_addr),  
    .i2c_rh_wl          (i2c_rh_wl),        //�̶�Ϊ0��ֻ�õ���IIC������д����   
    .i2c_addr           ({i2c_data[15:8],i2c_data[23:16]}),   
    .i2c_data_w         (i2c_data[7:0]),   
    .i2c_data_r         (i2c_data_r),   
    .i2c_done           (i2c_done  ),
    
    .scl                (iic_scl   ),   
    .sda                (iic_sda   ),   

    .dri_clk            (i2c_dri_clk)       //I2C����ʱ��
    );	

endmodule
