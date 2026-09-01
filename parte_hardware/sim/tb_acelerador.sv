`timescale 1ns / 1ps

module tb_acelerador();

    logic clk;
    logic rst_n;
    logic rx;
    logic tx;

    // Tempo de um bit na serial (para 50MHz e 115200 Baud)
    localparam int TEMPO_BIT = (50_000_000 / 115200) * 20; 

    // Instancia o acelerador
    acelerador_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .tx(tx)
    );

    // Gera o clock de 50 MHz (período de 20ns)
    always #10 clk = ~clk;

    // Tarefa para simular o PC enviando 1 byte via USB
    task envia_byte_serial(input logic [7:0] dado);
        begin
            rx = 1'b0; // Start bit
            #(TEMPO_BIT);
            
            for (int i = 0; i < 8; i++) begin
                rx = dado[i]; // Envia bit a bit
                #(TEMPO_BIT);
            end
            
            rx = 1'b1; // Stop bit
            #(TEMPO_BIT);
        end
    endtask

    // Início da simulação
    initial begin
        // Condições iniciais
        clk   = 0;
        rst_n = 0;
        rx    = 1;

        #100;
        rst_n = 1; // Tira do reset
        #100;

        // Simula o envio de 4 bytes (formando uma palavra de 32 bits da imagem)
        // Exemplo: enviando o valor 32'h11223344
        envia_byte_serial(8'h44);
        envia_byte_serial(8'h33);
        envia_byte_serial(8'h22);
        envia_byte_serial(8'h11);

        // Aguarda um tempo para ver a reação do circuito
        #50000;
        
        $display("Simulacao finalizada.");
        $stop;
    end

endmodule